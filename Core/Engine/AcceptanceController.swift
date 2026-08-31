import Foundation

/// The Tab state machine, and the only place text acceptance is decided.
///
/// Rule 1 of the design — *the app never changes your text unless you press Tab* —
/// is enforced here by construction: the sole way to get an `.accept` outcome is
/// to feed this a Tab key while a suggestion is pending. Nothing else in the app
/// is allowed to call the inserter.
///
/// Accepting keys are Tab and left arrow, and nothing else. With no suggestion
/// pending both produce `.passThrough` and the host app sees them untouched —
/// swallowing either unconditionally would break form navigation, editor
/// indentation, and caret movement, which is the fastest way to get the app
/// switched off for good.
public final class AcceptanceController {
    public enum Outcome: Equatable {
        /// Let the key reach the app; nothing was showing.
        case passThrough
        /// Let the key reach the app, and treat this suggestion as rejected.
        case passThroughDismissing(Candidate)
        /// Swallow the key and insert `text`, first deleting `replaces`
        /// characters before the caret. `isFinal` is false when a second Tab would
        /// extend the insertion to the rest of the phrase.
        case accept(text: String, candidate: Candidate, isFinal: Bool, replaces: Int)
    }

    /// How long a half-accepted phrase stays extendable. Any other keystroke ends
    /// it sooner; this only guards the case where the user tabs, wanders off, and
    /// comes back to a text field that no longer means what they remember.
    private let extensionWindow: TimeInterval
    private let now: () -> Date

    private var pending: Candidate?
    /// What is still on offer, in the bites a Tab takes. Empty means the whole
    /// candidate has been accepted.
    private var remainingUnits: [String] = []
    /// False until the first Tab, because a correction's deletions are paid for
    /// once — by the press that begins the insertion, not by each one after it.
    private var hasTakenABite = false
    private var stagedAt: Date?

    public init(extensionWindow: TimeInterval = 4.0, now: @escaping () -> Date = Date.init) {
        self.extensionWindow = extensionWindow
        self.now = now
    }

    public var currentCandidate: Candidate? { pending }

    /// What the overlay should be showing: everything still on offer.
    ///
    /// The whole remainder, never one word of it. The pill has to show what is
    /// being offered for the offer to be judgeable — "let" tells you nothing
    /// about whether the phrase is "let me know if that works" or "let's talk
    /// on Friday", and a suggestion you cannot evaluate is one you cannot
    /// safely take.
    public var displayText: String? {
        guard pending != nil else { return nil }
        let remaining = remainingUnits.joined()
        return remaining.isEmpty ? nil : remaining
    }

    public var hasPendingSuggestion: Bool { pending != nil }

    public func present(_ candidate: Candidate) {
        pending = candidate
        remainingUnits = candidate.acceptanceUnits
        hasTakenABite = false
        stagedAt = nil
    }

    public func clear() {
        pending = nil
        remainingUnits = []
        hasTakenABite = false
        stagedAt = nil
    }

    public func handle(_ key: KeyEvent) -> Outcome {
        // A modifier chord is the user driving an app, not composing text. Leave
        // the suggestion standing rather than dismissing on every Cmd-S.
        if key.isCommandChord { return .passThrough }

        if key.isAcceptKey { return handleAccept() }

        guard let candidate = pending else { return .passThrough }

        if key.isEscape {
            clear()
            return .passThroughDismissing(candidate)
        }

        // Anything else means the user kept typing, so the suggestion is stale.
        // A fresh prediction will follow from the Coordinator's debounce.
        clear()
        return .passThroughDismissing(candidate)
    }

    /// One Tab, one bite.
    ///
    /// Uniform and repeatable, which the previous version was not: it took one
    /// word on the first press and then *all* of the rest on the second, so a
    /// five-word phrase could be taken as one word or as five, and never as
    /// three. Partial correctness is the common case — four words right and the
    /// fifth wrong — and an all-or-nothing second press threw away the four.
    ///
    /// An atomic candidate has exactly one bite, so identity and corrections
    /// still land whole on a single press.
    private func handleAccept() -> Outcome {
        guard let candidate = pending, !remainingUnits.isEmpty else {
            // Nothing pending: Tab and left arrow are the host app's, untouched.
            // Swallowing either unconditionally would break form navigation,
            // editor indentation, and simply moving the caret.
            clear()
            return .passThrough
        }

        // A phrase half-taken and then abandoned must not resume: the caret may
        // be somewhere else entirely by now, and continuing would insert the
        // remainder into whatever the user has since moved to.
        guard !hasTakenABite || isExtensionLive else {
            clear()
            return .passThrough
        }

        let unit = remainingUnits.removeFirst()
        // Deletions belong to the press that starts the insertion; after that the
        // superseded characters are already gone.
        let replaces = hasTakenABite ? 0 : candidate.replacesPreviousCharacters
        hasTakenABite = true
        stagedAt = now()

        let isFinal = remainingUnits.isEmpty
        if isFinal { clear() }
        return .accept(text: unit, candidate: candidate, isFinal: isFinal, replaces: replaces)
    }

    private var isExtensionLive: Bool {
        guard let stagedAt else { return false }
        return now().timeIntervalSince(stagedAt) <= extensionWindow
    }
}
