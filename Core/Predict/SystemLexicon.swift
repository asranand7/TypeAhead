import AppKit
import Foundation

/// General word completions from macOS's own lexicon, so the app is useful on
/// the first keystroke rather than after weeks of training.
///
/// The original design had a cold-start problem: with only personal memory, a new
/// install knows nothing and suggests nothing, and the user has to invest days
/// before getting anything back. That is a bad trade to ask of someone.
///
/// `NSSpellChecker` already carries a frequency-ordered lexicon for the user's
/// locale — "recei" returns received, receipt, receive, receiving, in that order.
/// Using it means no word list to ship, no staleness, and it is automatically
/// right for whichever language the system is set to (here, en_IN, which is also
/// why it knows some Hinglish already).
///
/// Ranked deliberately *below* personal memory: these are guesses about English,
/// while the personal model knows what this person writes. A word you have used
/// twice outranks anything here, so the general layer fades as the personal one
/// grows — which is the behaviour you want, without a switch to flip.
public final class SystemLexicon: SuggestionSource {
    public let name = "System dictionary"

    /// Below three characters almost every word in the language matches, so the
    /// top completion is close to a coin flip and not worth the visual noise.
    private static let minimumPrefix = 3

    /// Except when the grammar pins the form down.
    ///
    /// The three-character floor was set before `GrammarFilter` existed, when
    /// frequency was the only signal and "do" really was a coin flip between do,
    /// does, don't, doing, download and dollar. It is not a coin flip after "I
    /// am": the preceding word rules out every one of those but "doing". So the
    /// floor drops to two exactly when there is something other than frequency
    /// to decide with, and holds at three when there is not.
    private static let constrainedMinimumPrefix = 2

    /// How many completions to *offer*. The lexicon is frequency-ordered, so the
    /// tail is rapidly worthless.
    private static let candidateLimit = 4

    /// How many to consider when the caret sits inside a word.
    ///
    /// Only then. The word already ahead of the caret is a hard eliminator — a
    /// completion either spans it or is simply wrong — so a wide list costs
    /// nothing and is necessary: "receiving" is the *fifth* completion of
    /// "recei", and with the ordinary limit of four it was never in the running.
    ///
    /// Widening it unconditionally is what must not happen. `GrammarFilter.form`
    /// cannot tell an adjective from a base-form verb, so a longer list quietly
    /// admits "considerable" as a candidate for "I will conside…", where it
    /// outranks "consider" on length alone. With no tail to filter by, the
    /// frequency ordering is the only signal there is, and four is where it is
    /// still worth something.
    private static let tailFilterLimit = 12

    /// Confidence for the first completion, decaying down the list.
    ///
    /// The lexicon is frequency-ordered, so its top hit is meaningfully better
    /// than a coin flip — "recei" really does mean "received" most of the time.
    /// Still set below what a twice-seen personal word scores, so personal memory
    /// keeps winning.
    private static let leadingConfidence = 0.45
    /// Steep on purpose. With a gentle decay the expected-savings formula picks
    /// the *longest* completion rather than the right one — "recomm" became
    /// "recommendation" (7 chars x 0.19 = 1.33) instead of "recommend"
    /// (2 x 0.45 = 0.90). The lexicon is frequency-ordered and that ordering is
    /// worth far more than the extra characters.
    ///
    /// Tuned, not guessed: it has to be steep enough that a third-place inflection
    /// loses to a first-place one despite being longer, and shallow enough that a
    /// second-place completion still clears the gate — "conside" must still offer
    /// "ring". That leaves a narrow band, and 0.48 sits in it.
    private static let decay = 0.48

    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    public init() {}

    public func suggest(_ context: TypingContext) -> [Candidate] {
        let prefix = context.currentWordPrefix
        let constrained = GrammarFilter.expectedForm(
            in: context.textBeforeCaret, before: prefix) != nil
        let floor = constrained
            ? SystemLexicon.constrainedMinimumPrefix
            : SystemLexicon.minimumPrefix
        guard prefix.count >= floor else { return [] }
        // Only complete plain lowercase-ish words; the lexicon has nothing useful
        // to say about identifiers, URLs or code.
        guard prefix.allSatisfy({ $0.isLetter }) else { return [] }

        let tail = context.currentWordSuffix
        let considered = tail.isEmpty
            ? SystemLexicon.candidateLimit
            : SystemLexicon.tailFilterLimit
        var words = completions(for: prefix).prefix(considered).filter {
            // Case-insensitive prefix match, but the remainder must come from the
            // real word so casing inside it is preserved.
            $0.count > prefix.count && $0.lowercased().hasPrefix(prefix.lowercased())
        }
        guard !words.isEmpty else { return [] }

        // Hard filter: with the caret inside a word, only a completion that spans
        // the text already ahead of it can possibly be right.
        if !tail.isEmpty {
            words = words.filter { $0.dropFirst(prefix.count).hasSuffix(tail) }
            guard !words.isEmpty else { return [] }
        }

        // Grammar outranks frequency, rather than merely nudging it.
        //
        // Confidence used to be assigned by frequency rank and *then* adjusted,
        // which cannot work: the decay is 0.48 per rank, so three ranks is a
        // factor of nine and no plausible boost closes that. The grammatical
        // constraint is not a preference to be weighed against frequency — it
        // rules alternatives out — so it decides the order, and frequency breaks
        // ties within each group.
        if let expected = GrammarFilter.expectedForm(in: context.textBeforeCaret,
                                                     before: prefix) {
            words = SystemLexicon.ordered(words, matching: expected)
        }

        var confidence = SystemLexicon.leadingConfidence
        var results: [Candidate] = []
        for word in words.prefix(SystemLexicon.candidateLimit) {
            defer { confidence *= SystemLexicon.decay }
            results.append(Candidate(text: String(word.dropFirst(prefix.count)),
                                     probability: confidence,
                                     origin: .lexicon))
        }
        // Still applied, for the finer-grained confidence within the new order.
        return GrammarFilter.adjust(results,
                                    prefix: prefix,
                                    context: context.textBeforeCaret)
    }

    /// Words in the expected grammatical form first, then those whose form cannot
    /// be determined, then the rest — each group keeping its frequency order.
    ///
    /// A stable partition rather than a sort, so the lexicon's ordering is
    /// preserved wherever grammar has nothing to say.
    static func ordered(_ words: [String], matching expected: GrammarFilter.Form) -> [String] {
        var matching: [String] = []
        var unknown: [String] = []
        var rest: [String] = []
        for word in words {
            switch GrammarFilter.form(of: word) {
            case expected: matching.append(word)
            case .unknown: unknown.append(word)
            default: rest.append(word)
            }
        }
        return matching + unknown + rest
    }

    /// Cached because this runs on the keystroke path. The underlying call is
    /// about 4ms — fine once, wasteful on every character of every word.
    private func completions(for prefix: String) -> [String] {
        let key = prefix.lowercased()

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let range = NSRange(location: 0, length: prefix.utf16.count)
        let words = NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: prefix,
            language: nil,          // follow the system's own language setting
            inSpellDocumentWithTag: 0) ?? []

        lock.lock()
        // Bounded: a long session would otherwise accumulate an entry per prefix
        // of every word ever typed.
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = words
        lock.unlock()
        return words
    }
}
