import Cocoa

/// Wires the pieces together and owns nothing else.
///
/// Every decision of substance lives elsewhere — ranking in `SuggestionEngine`,
/// acceptance in `AcceptanceController`, learning behind `TypingObserver`. This
/// class routes keystrokes between them and manages the debounce. Keeping it thin
/// is what stops it becoming the place every future feature gets bolted onto.
public final class Coordinator: NSObject, KeyTapDelegate {
    private let tap = KeyTap()
    private let contextReader = ContextReader()
    private let overlay = SuggestionOverlay()
    private let inlineGhost = InlineGhost()
    private let inserter = Inserter()
    private let engine: SuggestionEngine
    private let acceptance: AcceptanceController
    private let signals: TypingSignalBus
    private let settings: Settings

    /// Wait after the last keystroke before predicting. Long enough that a fast
    /// typist is not interrupted mid-word, short enough to feel immediate.
    private static let debounce: TimeInterval = 0.04

    private let predictionQueue = DispatchQueue(label: "com.typeahead.prediction", qos: .userInteractive)
    /// Serial, so a show and the remove that follows it cannot overlap — two
    /// Accessibility mutations racing on the same field is how stray text is left
    /// behind.
    private let insertionQueue = DispatchQueue(label: "com.typeahead.insertion", qos: .userInteractive)
    private var pendingPrediction: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var partialWord = ""

    /// Bumped on every user keystroke and every caret move.
    ///
    /// Prediction reads the context on a background thread and shows the ghost on
    /// the main one. Anything typed in between makes the suggestion stale — it was
    /// computed for a shorter prefix, so inserting it duplicates characters:
    /// "Ana" + suggestion "nd", inserted after you already typed "nd", gives
    /// "Anandnd". Comparing the generation before showing is what makes that
    /// impossible rather than merely unlikely.
    private var keystrokeGeneration = 0

    public private(set) var isEnabled = false

    /// Called whenever enablement changes, so the menu bar can re-render without
    /// the Coordinator knowing a menu bar exists.
    public var onStateChange: ((Bool) -> Void)?

    public init(engine: SuggestionEngine,
                settings: Settings = Settings(),
                acceptance: AcceptanceController = AcceptanceController(),
                signals: TypingSignalBus = TypingSignalBus()) {
        self.engine = engine
        self.settings = settings
        self.acceptance = acceptance
        self.signals = signals
        super.init()
        tap.delegate = self
    }

    public func addObserver(_ observer: TypingObserver) {
        signals.add(observer)
    }

    /// Learning signals are suppressed while learning is paused; presentation
    /// signals (shown/accepted/rejected) always flow, because the savings metric
    /// and the confidence gate should keep working even when nothing new is being
    /// remembered.
    private func emit(_ signal: TypingSignal) {
        switch signal {
        case .typed, .wordCommitted, .backspaced:
            guard !settings.isLearningPaused else { return }
        case .caretMoved, .suggestionShown, .suggestionAccepted, .suggestionRejected:
            break
        }
        signals.observe(signal)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func enable() -> Bool {
        guard !isEnabled else { return true }
        guard tap.start() else { return false }
        ElectronAccessibility.enableForFrontmostApp()
        observeCaretDisplacement()
        isEnabled = true
        onStateChange?(true)
        return true
    }

    public func disable() {
        guard isEnabled else { return }
        cancelPrediction()
        dismissSuggestion(rejecting: true)
        tap.stop()
        stopObservingCaretDisplacement()
        isEnabled = false
        onStateChange?(false)
    }

    public func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    // MARK: - KeyTapDelegate

    public func keyTap(_ tap: KeyTap, shouldSwallow event: KeyEvent) -> Bool {
        // The inline ghost is real text in the user's document, so it comes back
        // out before any key that is not an accept key reaches the app — Return
        // above all.
        // Letting Return through with the ghost still in place would send the
        // suggestion along with the message in a chat box. This ordering is the
        // whole safety argument for putting text in the field at all.
        // The ghost is real text in the document, so it must not survive a key
        // that is not an accept key. There are two ways to ensure that, and which
        // one is used matters a great deal.
        //
        // For an ordinary character, the app does it for us: typing over a
        // selection replaces it, in every text field there is. Deleting first is
        // both unnecessary and risky, so we simply forget the ghost and let the
        // keystroke land.
        //
        // For anything that does *not* replace a selection — Return, Escape,
        // arrows, Delete — the ghost would survive, so it is removed explicitly.
        // Return is the one that matters: in a chat box it would otherwise send
        // the suggestion along with the message.
        if !event.isAcceptKey, inlineGhost.isShowing {
            // A typed ghost beginning with a space must never be left for the app
            // to replace: our space and the user's next one become adjacent in the
            // input stream, and macOS turns a double space into ". " on its own.
            // Removing explicitly puts deletions between them.
            let replacedByTyping = !event.characters.isEmpty
                && !event.isCommandChord
                && !event.isReturn
                && !event.isBackspace
                && !inlineGhost.typedLeadingWhitespace

            if replacedByTyping {
                // Nothing to undo: the app replaces a selection when you type over
                // it. Forgetting the ghost is a field assignment, so the main
                // thread is free immediately.
                inlineGhost.relinquish()
            } else {
                // Return, Escape, arrows and Delete do not replace a selection, so
                // the ghost has to be taken out — which is Accessibility work and
                // must not happen here. Swallow the key, remove off-thread, then
                // re-send it. Ordering is preserved and the tap returns at once.
                acceptance.clear()
                noteUserKeystroke(event)
                schedulePrediction()
                let keyCode = event.keyCode
                let flags = event.modifiers
                insertionQueue.async { [weak self] in
                    guard let self else { return }
                    self.inlineGhost.remove()
                    self.inserter.resend(keyCode: keyCode, flags: flags)
                }
                return true
            }
        }

        // A blocked app is invisible to the whole pipeline: nothing observed,
        // nothing suggested, nothing stored. Checked before the state machine so
        // no partial state can survive switching into a blocked app.
        if settings.isBlocked(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            if acceptance.hasPendingSuggestion { dismissSuggestion(rejecting: false) }
            return false
        }

        switch acceptance.handle(event) {
        case .accept(let text, let candidate, let isFinal, let replaces):
            accept(text: text, candidate: candidate, isFinal: isFinal, replaces: replaces)
            return true

        case .passThroughDismissing(let candidate):
            overlay.hide()
            emit(.suggestionRejected(candidate))
            noteUserKeystroke(event)
            schedulePrediction()
            return false

        case .passThrough:
            noteUserKeystroke(event)
            schedulePrediction()
            return false
        }
    }

    /// Keystrokes went missing, so the partial word we were accumulating is
    /// incomplete and the shadow buffer no longer matches the document. Committing
    /// the fragment is better than letting the next keystrokes glue onto it — that
    /// produces tokens like "workighow" that pollute the vocabulary permanently.
    public func keyTapDidLoseEvents(_ tap: KeyTap) {
        partialWord = ""
        contextReader.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            self?.dismissSuggestion(rejecting: false)
        }
    }

    /// The only call site of `Inserter.insert` in the app. Rule 1 is a one-line
    /// grep away from being verified, and the test suite does exactly that.
    private func accept(text: String, candidate: Candidate, isFinal: Bool, replaces: Int) {
        if inlineGhost.isShowing {
            // Already in the document — accepting only collapses the selection.
            insertionQueue.async { [weak self] in self?.inlineGhost.accept() }
        } else {
            insertionQueue.async { [weak self] in
                self?.inserter.insert(text, replacingPrevious: replaces)
            }
            for _ in 0..<replaces { contextReader.noteBackspace() }
        }
        contextReader.noteTyped(text)
        emit(.suggestionAccepted(candidate, characters: text.count))

        if isFinal {
            overlay.hide()
            schedulePrediction()
        } else if let staged = acceptance.displayText {
            // A phrase was partly taken. Show what is left of it, so the pill
            // always displays exactly what remains on offer.
            present(staged, candidate: nil)
        }
    }

    /// Shows `text` as a pill just above the caret.
    ///
    /// The pill is the presentation, not a fallback. Inline was tried and
    /// withdrawn: it needs the app to accept an Accessibility write *and* not
    /// revert it, and most of the apps people actually write in fail one of those
    /// — React-controlled fields revert on their next render, terminals and
    /// canvas editors refuse outright, and a caret anywhere but the end of the
    /// field is declined by design. The result was an app that showed nothing
    /// almost everywhere, which from the outside is indistinguishable from being
    /// broken. `inlineEnabled` is off by default and kept only as an opt-in
    /// escape hatch; with it off nothing here touches the document until Tab.
    ///
    /// **Nothing in this path may block the writer.** Every Accessibility call
    /// blocks until the target app answers, so all of them happen off the main
    /// thread and every one of them is allowed to fail into silence. A missing
    /// suggestion is a non-event; a stalled keystroke is not, and a tap callback
    /// slow enough to be noticed gets the tap disabled by the system outright.
    private func present(_ text: String, candidate: Candidate?) {
        let generation = keystrokeGeneration
        insertionQueue.async { [weak self] in
            guard let self else { return }

            // The queue is serial and a caret query costs several Accessibility
            // round trips. If more keys have landed since this was scheduled the
            // pill is already wrong, so drop it *before* paying for it — that is
            // what lets a fast typist drain the backlog instead of building one
            // and watching pills arrive a second behind the words.
            guard generation == self.keystrokeGeneration else { return }

            if self.settings.inlineEnabled, self.inlineGhost.show(text) {
                DispatchQueue.main.async { [weak self] in
                    self?.overlay.hide()
                    if let candidate { self?.emit(.suggestionShown(candidate)) }
                }
                return
            }

            let caret = self.contextReader.caretRect()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled,
                      generation == self.keystrokeGeneration,
                      self.acceptance.hasPendingSuggestion else { return }
                // Nothing focused, or an app that will answer no geometry query
                // at all. A pill parked in the middle of the screen, unrelated to
                // where anyone is looking, is worse than no pill: this is where
                // silence is the honest outcome.
                guard let caret else { self.overlay.hide(); return }
                self.overlay.show(text: text, at: caret)
                // Emitted here and nowhere else: "shown" has to mean the user
                // could actually see it. Reporting it from the prediction path
                // instead recorded every suggestion the app merely computed —
                // including, for the whole period when the pill had no call site,
                // hundreds that were never drawn at all. That made the feedback
                // table useless for the one thing it exists for, and the
                // acceptance rates derived from it fiction.
                if let candidate { self.emit(.suggestionShown(candidate)) }
            }
        }
    }

    // MARK: - Keystroke bookkeeping

    private func noteUserKeystroke(_ event: KeyEvent) {
        keystrokeGeneration &+= 1

        if event.isBackspace {
            contextReader.noteBackspace()
            if !partialWord.isEmpty { partialWord.removeLast() }
            emit(.backspaced)
            return
        }

        if event.isArrow {
            contextReader.invalidateShadow()
            commitPartialWord()
            emit(.caretMoved)
            return
        }

        guard !event.characters.isEmpty, !event.isCommandChord else { return }
        contextReader.noteTyped(event.characters)
        emit(.typed(event.characters))
        accumulate(event.characters)
    }

    /// Tracks the token under construction so a completed word can be announced
    /// exactly once, on the character that ends it.
    private func accumulate(_ characters: String) {
        for character in characters {
            if let scalar = character.unicodeScalars.first,
               ContextReader.isWordCharacter(scalar) {
                partialWord.append(character)
            } else {
                commitPartialWord()
            }
        }
    }

    private func commitPartialWord() {
        guard !partialWord.isEmpty else { return }
        let word = partialWord
        partialWord = ""
        emit(.wordCommitted(
            word: word,
            appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    // MARK: - Prediction

    private func schedulePrediction() {
        cancelPrediction()
        let work = DispatchWorkItem { [weak self] in self?.predict() }
        pendingPrediction = work
        predictionQueue.asyncAfter(deadline: .now() + Coordinator.debounce, execute: work)
    }

    private func cancelPrediction() {
        pendingPrediction?.cancel()
        pendingPrediction = nil
    }

    /// Runs off the main thread: an Accessibility read blocks until the focused
    /// app answers, and a slow app must never stall the keystroke path.
    private func predict() {
        let generation = keystrokeGeneration
        let context = contextReader.read()
        guard !settings.isBlocked(context.appBundleID) else { return }
        let candidate = engine.bestCandidate(for: context)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            // Anything typed since the context was read invalidates this
            // suggestion. Showing it anyway is what produced "Anandnd".
            guard generation == self.keystrokeGeneration else { return }
            guard let candidate else {
                self.dismissSuggestion(rejecting: false)
                return
            }
            self.acceptance.present(candidate)
            // The whole phrase, not the first word of it. You cannot evaluate an
            // offer you cannot see: shown "let", there is no way to tell whether
            // the phrase is "let me know if that works" or "let's talk Friday".
            // Tab still takes one word at a time — what is displayed and what a
            // single press takes are simply different questions.
            self.present(candidate.text, candidate: candidate)
        }
    }

    private func dismissSuggestion(rejecting: Bool) {
        if rejecting, let candidate = acceptance.currentCandidate {
            emit(.suggestionRejected(candidate))
        }
        acceptance.clear()
        insertionQueue.async { [weak self] in self?.inlineGhost.remove() }
        overlay.hide()
    }

    // MARK: - Caret displacement

    /// A click or an app switch moves the caret somewhere the shadow buffer cannot
    /// follow. Invalidating is cheap; a stale context produces confidently wrong
    /// suggestions, which is far more damaging than none.
    private func observeCaretDisplacement() {
        // Scrolling moves the text under the caret without producing a keystroke,
        // so nothing else in this class would ever hear about it — and the pill
        // would sit stranded over the middle of the document, pointing at a line
        // that has moved. Only the presentation is torn down: the shadow buffer
        // and the partial word are still valid, because scrolling does not move
        // the insertion point, and treating it as a caret move would throw away
        // context on every flick of the trackpad.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] _ in
            guard let self, self.acceptance.hasPendingSuggestion else { return }
            self.acceptance.clear()
            self.overlay.hide()
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            ElectronAccessibility.enableForFrontmostApp()
            self.contextReader.invalidateShadow()
            self.commitPartialWord()
            self.dismissSuggestion(rejecting: true)
            self.emit(.caretMoved)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationSwitched),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    private func stopObservingCaretDisplacement() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func applicationSwitched() {
        keystrokeGeneration &+= 1
        // Electron apps expose nothing to Accessibility until asked. Do it on
        // every switch, before the first prediction in the new app.
        ElectronAccessibility.enableForFrontmostApp()
        contextReader.invalidateShadow()
        commitPartialWord()
        dismissSuggestion(rejecting: false)
        emit(.caretMoved)
    }
}
