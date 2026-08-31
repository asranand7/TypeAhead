import Foundation

/// Notices phrases you repeat and promotes them to snippets.
///
/// The single biggest source of keystroke savings: one Tab can land a whole line
/// ("Thanks, Anand", "Let me know if that works", "Please find attached"). Those
/// are invisible to an n-gram model asked for one word at a time, because their
/// value is in being taken whole.
///
/// Mines rather than asks: the user never has to think about what to add.
public final class SnippetMiner: TypingObserver {
    /// Shortest sequence worth remembering.
    ///
    /// Four was too high — nothing was ever offered until a whole four-word
    /// phrase repeated, so the highest-value tier stayed empty. Two was too low,
    /// for a subtler reason: a two-word phrase is a bigram, and the n-gram model
    /// already holds every one of them with proper backoff and discounting.
    /// Storing them here as well produced a second, redundant copy that competed
    /// with the original and won on length. A real store had "are you" (10) and
    /// "i s" (8) sitting in the snippet tier as though they were phrases.
    ///
    /// Three is the shortest length that is genuinely a phrase rather than a
    /// bigram the statistics tier already knows.
    public static let minimumWords = 3
    /// Longest sequence tracked. Beyond this the chance of an exact repeat is low
    /// enough that the bookkeeping stops paying for itself.
    public static let maximumWords = 8
    /// Repeats before a candidate becomes a snippet the user actually sees.
    /// Twice is a habit; waiting for a third meant most real phrases never made it.
    public static let promotionThreshold = 2

    private let store: Store
    private let lock = NSLock()
    private var recent: [String] = []

    public init(store: Store) {
        self.store = store
    }

    public func observe(_ signal: TypingSignal) {
        switch signal {
        case .wordCommitted(let word, _):
            record(word)
        case .caretMoved:
            // The caret jumped, so words either side of the jump were never
            // adjacent. Joining them would mine phrases the user never typed.
            lock.lock()
            recent.removeAll()
            lock.unlock()
        default:
            break
        }
    }

    private func record(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        lock.lock()
        recent.append(cleaned)
        if recent.count > SnippetMiner.maximumWords {
            recent.removeFirst(recent.count - SnippetMiner.maximumWords)
        }
        let window = recent
        lock.unlock()

        // Every trailing sequence long enough to qualify. Counting all lengths
        // lets the longest repeated phrase win naturally, rather than committing
        // early to a fixed size.
        guard window.count >= SnippetMiner.minimumWords else { return }
        for length in SnippetMiner.minimumWords...window.count {
            let phrase = window.suffix(length).joined(separator: " ")
            try? store.recordSnippet(phrase, source: "auto")
        }
    }

    /// How much of a phrase's weight an extension must carry before the shorter
    /// phrase is treated as redundant. See `SnippetSource.maximal`.
    public static let closureRatio = 0.8

    /// Snippets that have repeated often enough to be worth offering.
    public func promoted() throws -> [Store.Snippet] {
        try store.allSnippets().filter {
            $0.source == "manual" || $0.count >= SnippetMiner.promotionThreshold
        }
    }
}

/// Offers whole phrases the user has typed before.
///
/// Registered as its own `SuggestionSource` rather than folded into
/// `PersonalModel`, because it answers a different question: not "what word comes
/// next" but "have you written this entire sentence before".
public final class SnippetSource: SuggestionSource {
    public let name = "Snippets"

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    public func suggest(_ context: TypingContext) -> [Candidate] {
        // Match against the tail of what has been typed, so a snippet can be
        // offered part-way through writing it.
        let tail = SnippetSource.matchableTail(of: context.textBeforeCaret)
        guard tail.count >= 2 else { return [] }

        guard let matches = try? store.snippets(startingWith: tail) else { return [] }
        return SnippetSource.maximal(matches).compactMap { snippet in
            guard snippet.source == "manual" || snippet.count >= SnippetMiner.promotionThreshold
            else { return nil }
            guard snippet.text.count > tail.count else { return nil }

            let remainder = String(snippet.text.dropFirst(tail.count))
            // Confidence grows with repetition but is capped: a snippet seen
            // twenty times is not a certainty, it is a habit.
            let confidence = min(0.35 + Double(snippet.count) * 0.06, 0.8)
            return Candidate(text: remainder, probability: confidence, origin: .snippet)
        }
    }

    /// Drops phrases that are merely the opening of a longer one.
    ///
    /// The miner records every trailing sequence, which is how the longest
    /// repeated phrase is discovered — but it means typing "Where are you from"
    /// twice creates a snippet for *every* sub-phrase. A real store held six
    /// entries for that one sentence: "Where are", "are you", "you from",
    /// "Where are you", "are you from", and the whole thing. All six matched the
    /// same tail, all six were offered, and the ranker took whichever was
    /// longest. The tier was not mining phrases, it was enumerating substrings.
    ///
    /// A phrase earns its own entry only if it occurs meaningfully often *without*
    /// its usual continuation. "Where are" seen 11 times, of which 9 continue
    /// "you", is not a phrase anyone means on its own — it is the head of one.
    /// Comparing against `closureRatio` is what tells those apart, and it is the
    /// standard closed-n-gram test.
    public static func maximal(_ snippets: [Store.Snippet]) -> [Store.Snippet] {
        snippets.filter { snippet in
            !snippets.contains { other in
                other.text != snippet.text
                    && other.text.hasPrefix(snippet.text)
                    && Double(other.count)
                        >= Double(snippet.count) * SnippetMiner.closureRatio
            }
        }
    }

    /// The text since the last sentence boundary, which is what a snippet is
    /// matched against. Anything earlier is a different sentence.
    public static func matchableTail(of text: String) -> String {
        var tail = ""
        for character in text.reversed() {
            if ".!?\n".contains(character) { break }
            tail.insert(character, at: tail.startIndex)
        }
        return tail.trimmingCharacters(in: .whitespaces)
    }
}
