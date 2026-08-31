import Cocoa
import InputMethodKit
import TypeAheadCore

/// The input-method front-end: suggestions rendered *inside* the text field.
///
/// Uses marked text — the same mechanism every CJK input method uses to show what
/// you are composing before you commit it. The host application draws it, at the
/// caret, in its own font, which is why it lands in the right place in every app
/// without any of the caret-geometry guesswork the overlay needs.
///
/// ## The safety design
///
/// An input method sits in the path of every keystroke on the machine. If it
/// misbehaves, typing breaks everywhere — a far worse failure than an event tap,
/// which fails open.
///
/// So this controller **passes through everything it does not own**. Ordinary
/// characters are never consumed, never re-inserted, never transformed: `handle`
/// returns `false` and the system delivers the keystroke natively, exactly as if
/// no input method were installed. Only Tab and Escape are ever consumed, and only
/// while a suggestion is actually on screen.
///
/// That means a bug here degrades to "no suggestions", not "cannot type".
@objc(TypeAheadInputController)
final class TypeAheadInputController: IMKInputController {
    /// The suggestion currently shown as marked text, if any.
    private var pending: Candidate?
    /// Set after a first Tab takes one word of a phrase, holding the remainder.
    private var phraseRemainder: String?
    private var pendingWork: DispatchWorkItem?

    /// A local echo of the current word, used when the client will not report its
    /// own contents. Reset whenever continuity is lost.
    private var partialWord = ""

    private var engine: IMEngine { IMEngine.shared }

    // MARK: - Key handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }

        // Modifier chords belong to the app. Never touch them.
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            clearSuggestion(client)
            return false
        }

        switch Int(event.keyCode) {
        case kVK_Tab:
            return handleTab(client)

        case kVK_Escape:
            if pending != nil {
                clearSuggestion(client)
                return true
            }
            return false

        case kVK_Delete:
            clearSuggestion(client)
            if !partialWord.isEmpty { partialWord.removeLast() }
            engine.observe(.backspaced)
            schedulePrediction(client)
            return false

        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            clearSuggestion(client)
            commitPartialWord()
            engine.observe(.caretMoved)
            return false

        default:
            // Everything else: clear any ghost, let the app have the key untouched,
            // then predict from the new state.
            clearSuggestion(client)
            note(event)
            schedulePrediction(client)
            return false
        }
    }

    /// Tab is the only key that ever accepts — rule 1, unchanged from the overlay
    /// front-end. With nothing pending it passes straight through, so Tab still
    /// indents and still moves between fields.
    private func handleTab(_ client: IMKTextInput) -> Bool {
        if let remainder = phraseRemainder, let candidate = pending {
            clearMarkedText(client)
            client.insertText(remainder, replacementRange: NSRange(location: NSNotFound, length: 0))
            engine.observe(.suggestionAccepted(candidate, characters: remainder.count))
            pending = nil
            phraseRemainder = nil
            return true
        }

        guard let candidate = pending else { return false }

        clearMarkedText(client)

        // A correction replaces what was typed, so the characters it supersedes
        // have to go. `replacementRange` does that in one step, without
        // synthesising backspaces the app would see as real edits.
        var replacement = NSRange(location: NSNotFound, length: 0)
        if candidate.replacesPreviousCharacters > 0 {
            let selected = client.selectedRange()
            let start = max(0, selected.location - candidate.replacesPreviousCharacters)
            replacement = NSRange(location: start, length: selected.location - start)
        }

        let first = candidate.isMultiWord ? candidate.firstWord : candidate.text
        client.insertText(first, replacementRange: replacement)
        engine.observe(.suggestionAccepted(candidate, characters: first.count))

        if candidate.isMultiWord {
            phraseRemainder = String(candidate.text.dropFirst(first.count))
            // Show what a second Tab would add, so the two-stage accept is visible
            // rather than something you have to know about.
            showMarked(phraseRemainder ?? "", client)
        } else {
            pending = nil
            phraseRemainder = nil
        }
        return true
    }

    // MARK: - Marked text

    /// Puts `text` in the field as marked text with the caret *before* it, so it
    /// reads as a suggestion sitting ahead of the cursor rather than as something
    /// already typed.
    private func showMarked(_ text: String, _ client: IMKTextInput) {
        guard !text.isEmpty else { return }
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttributes(
            mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: text.count))
                as? [NSAttributedString.Key: Any] ?? [:],
            range: NSRange(location: 0, length: text.count))

        client.setMarkedText(attributed,
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func clearMarkedText(_ client: IMKTextInput) {
        client.setMarkedText("",
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func clearSuggestion(_ client: IMKTextInput) {
        pendingWork?.cancel()
        if let candidate = pending {
            clearMarkedText(client)
            engine.observe(.suggestionRejected(candidate))
        }
        pending = nil
        phraseRemainder = nil
    }

    // MARK: - Prediction

    private func schedulePrediction(_ client: IMKTextInput) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.predict(client)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func predict(_ client: IMKTextInput) {
        let context = readContext(client)
        guard let candidate = engine.bestSuggestion(for: context) else { return }

        // The ghost is only the part not yet typed. A correction is the exception:
        // it deliberately proposes replacing what is there.
        pending = candidate
        phraseRemainder = nil
        showMarked(candidate.text, client)
        engine.observe(.suggestionShown(candidate))
    }

    /// Reads the text before the caret from the client itself.
    ///
    /// Better than the Accessibility route the overlay uses: this is the input
    /// protocol the app already implements to support any input method, so far
    /// more apps answer it honestly. Falls back to the local echo when one does not.
    private func readContext(_ client: IMKTextInput) -> TypingContext {
        let bundleID = (client.bundleIdentifier() as String?)
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let selected = client.selectedRange()
        if selected.location != NSNotFound, selected.location > 0 {
            let start = max(0, selected.location - ContextReader.maxContextChars)
            let range = NSRange(location: start, length: selected.location - start)
            if let attributed = client.attributedSubstring(from: range),
               !attributed.string.isEmpty {
                let text = attributed.string
                return TypingContext(textBeforeCaret: text,
                                     currentWordPrefix: ContextReader.trailingWord(of: text),
                                     appBundleID: bundleID,
                                     isAuthoritative: true)
            }
        }

        return TypingContext(textBeforeCaret: partialWord,
                             currentWordPrefix: ContextReader.trailingWord(of: partialWord),
                             appBundleID: bundleID,
                             isAuthoritative: false)
    }

    // MARK: - Learning

    private func note(_ event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else { return }
        engine.observe(.typed(characters))

        for character in characters {
            if let scalar = character.unicodeScalars.first,
               ContextReader.isWordCharacter(scalar) {
                partialWord.append(character)
            } else {
                commitPartialWord()
            }
        }
        if partialWord.count > ContextReader.maxContextChars {
            partialWord.removeFirst(partialWord.count - ContextReader.maxContextChars)
        }
    }

    private func commitPartialWord() {
        guard !partialWord.isEmpty else { return }
        let word = partialWord
        partialWord = ""
        engine.observe(.wordCommitted(
            word: word,
            appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    // MARK: - Lifecycle

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            clearSuggestion(client)
        }
        commitPartialWord()
        engine.observe(.caretMoved)
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        // The app is taking the text — drop the ghost rather than let it be
        // committed along with what the user actually wrote. This is the failure
        // that would otherwise send a suggestion in a chat box on Enter.
        if let client = sender as? IMKTextInput {
            clearSuggestion(client)
        }
        super.commitComposition(sender)
    }
}
