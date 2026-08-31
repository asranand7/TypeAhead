import Foundation

/// Learns your typos by watching you fix them, and offers the fix next time.
///
/// The training signal is free and perfectly labelled: when you type a word,
/// delete it, and retype something similar, that is a correction pair nobody had
/// to annotate. The result is *your* finger habits — the transpositions your
/// hands actually make — rather than a generic dictionary of common misspellings.
///
/// Corrections are suggest-only, like everything else. Nothing is auto-applied;
/// the fix appears as ghost text and Tab takes it.
public final class Corrector: SuggestionSource, TypingObserver {
    public let name = "Corrections"

    /// Pairs must be seen this often before the fix is offered. Once could be a
    /// change of mind; twice is a pattern.
    public static let minimumEvidence = 2

    /// A word seen at least this often is *yours* — a name, jargon, a Hinglish
    /// spelling — and is never offered as something to correct.
    public static let protectionThreshold = 3

    private let store: Store
    private let lock = NSLock()

    private var lastCommittedWord: String?
    private var backspaceRun = 0
    private var deletedWord: String?

    public init(store: Store) {
        self.store = store
    }

    // MARK: - Learning

    public func observe(_ signal: TypingSignal) {
        switch signal {
        case .wordCommitted(let word, _):
            handleCommit(word)

        case .backspaced:
            handleBackspace()

        case .typed:
            // Typing resumes after a deletion; the run is over but the deleted
            // word stays pending until we see what replaces it.
            lock.lock(); backspaceRun = 0; lock.unlock()

        case .caretMoved:
            lock.lock()
            lastCommittedWord = nil
            deletedWord = nil
            backspaceRun = 0
            lock.unlock()

        case .suggestionShown, .suggestionAccepted, .suggestionRejected:
            break
        }
    }

    private func handleBackspace() {
        lock.lock()
        backspaceRun += 1
        // Deleting past the separator and through the whole word means the word
        // itself is being taken back, not merely trimmed.
        if let last = lastCommittedWord, backspaceRun >= last.count + 1 {
            deletedWord = last
            lastCommittedWord = nil
        }
        lock.unlock()
    }

    private func handleCommit(_ word: String) {
        let normalized = PersonalModel.normalize(word)

        lock.lock()
        let deleted = deletedWord
        deletedWord = nil
        backspaceRun = 0
        lastCommittedWord = normalized
        lock.unlock()

        guard let deleted, deleted != normalized else { return }
        guard Corrector.isPlausibleTypoFix(from: deleted, to: normalized) else { return }
        try? store.recordCorrection(wrong: deleted, right: normalized)
    }

    /// Distinguishes a typo fix from a change of mind.
    ///
    /// Rewriting "hello" as "hi" is editing, not correcting, and recording it
    /// would make the app "fix" a perfectly good word later. The edit distance has
    /// to be small relative to the length of what was written.
    public static func isPlausibleTypoFix(from wrong: String, to right: String) -> Bool {
        guard !wrong.isEmpty, !right.isEmpty else { return false }
        guard abs(wrong.count - right.count) <= 3 else { return false }
        let distance = editDistance(wrong, right)
        guard distance > 0 else { return false }
        let budget = max(1, min(wrong.count, right.count) / 3)
        return distance <= budget
    }

    /// Damerau-Levenshtein distance: like Levenshtein, but a transposition of two
    /// adjacent characters costs 1 rather than 2.
    ///
    /// That difference decides real cases. Transposition is the most common typing
    /// error there is — "teh" for "the", "adn" for "and" — and under plain
    /// Levenshtein every one of them scores 2, which puts short words outside any
    /// sane budget and makes the correction learner silently blind to them.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a), rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        // Three rows, because a transposition looks back two positions in both
        // strings and a two-row rolling window cannot reach that far.
        var twoBack = [Int](repeating: 0, count: rhs.count + 1)
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                var best = min(previous[j] + 1,          // deletion
                               current[j - 1] + 1,        // insertion
                               previous[j - 1] + cost)    // substitution

                if i > 1, j > 1,
                   lhs[i - 1] == rhs[j - 2],
                   lhs[i - 2] == rhs[j - 1] {
                    best = min(best, twoBack[j - 2] + 1)  // transposition
                }
                current[j] = best
            }
            twoBack = previous
            previous = current
            current = [Int](repeating: 0, count: rhs.count + 1)
        }
        return previous[rhs.count]
    }

    // MARK: - Suggesting

    public func suggest(_ context: TypingContext) -> [Candidate] {
        let typed = context.currentWordPrefix
        guard typed.count >= 3 else { return [] }
        let normalized = PersonalModel.normalize(typed)

        // Vocabulary protection: never offer to "fix" a word the user writes
        // often. This is what stops the app fighting them over names, jargon and
        // Hinglish spellings the way system autocorrect does.
        if isProtected(normalized) { return [] }

        guard let pair = try? store.correction(for: normalized),
              pair.count >= Corrector.minimumEvidence else { return [] }

        // Replaces what was typed rather than appending to it — the whole point
        // of a correction — and still only on Tab.
        let confidence = min(0.5 + Double(pair.count) * 0.1, 0.9)
        return [Candidate(text: Corrector.matchCasing(of: typed, to: pair.right),
                          probability: confidence,
                          origin: .correction,
                          replacesPreviousCharacters: typed.count)]
    }

    public func isProtected(_ word: String) -> Bool {
        if (try? store.isProtected(word)) == true { return true }
        let seen = (try? store.wordCount(word)) ?? 0
        return seen >= Corrector.protectionThreshold
    }

    /// Keeps the user's capitalisation. Storage folds case so "Recieve" and
    /// "recieve" are one pair, but the replacement has to come back looking like
    /// what they were writing.
    public static func matchCasing(of typed: String, to replacement: String) -> String {
        guard let first = typed.first else { return replacement }
        if typed.allSatisfy({ !$0.isLowercase }) && typed.count > 1 {
            return replacement.uppercased()
        }
        if first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
