import Foundation

/// The half of the app that actually knows you.
///
/// Learns from every word committed and predicts from what it has seen. It beats
/// a general model on the things typed most — names, jargon, repeated phrases,
/// and any language whose romanisation a small model has barely met — because it
/// is not modelling language, it is modelling *this person*.
///
/// Scored with stupid backoff. Kneser-Ney would estimate held-out probabilities
/// slightly better, but the ranker consumes P(accepted), not a language-model
/// probability, and acceptance feedback recalibrates it anyway. Simple wins.
public final class PersonalModel: SuggestionSource, TypingObserver {
    public let name = "Personal memory"

    /// Weight applied per level of backoff. The classic stupid-backoff constant.
    private static let backoffFactor = 0.4

    /// A word must have been seen at least this often before it is offered as a
    /// completion. One sighting is as likely to be a typo as a word.
    private static let minimumEvidence = 2

    private let store: Store
    private let hygiene: WordHygiene
    private let lock = NSLock()

    /// The last two committed word ids, oldest first. Reset whenever the caret
    /// moves somewhere we did not put it, because the preceding words are then
    /// unknown and a trigram built across the gap would be fiction.
    private var window: [Int64] = []

    public init(store: Store, hygiene: WordHygiene = WordHygiene()) {
        self.store = store
        self.hygiene = hygiene
    }

    // MARK: - Learning

    public func observe(_ signal: TypingSignal) {
        switch signal {
        case .wordCommitted(let word, let bundleID):
            learn(word: word, appBundleID: bundleID)

        case .caretMoved:
            lock.lock()
            window.removeAll()
            lock.unlock()

        case .suggestionShown(let candidate):
            try? store.recordShown(origin: candidate.origin, app: "")

        case .suggestionAccepted(let candidate, let characters):
            try? store.recordAccepted(origin: candidate.origin,
                                      app: "",
                                      charactersSaved: max(0, characters - 1))

        case .typed, .backspaced, .suggestionRejected:
            break
        }
    }

    private func learn(word: String, appBundleID: String?) {
        let normalized = PersonalModel.normalize(word)
        guard !normalized.isEmpty else { return }
        guard let id = try? store.recordWord(normalized) else { return }

        // Re-classified on every sighting, so an unrecognised word that keeps
        // recurring is promoted from 'unverified' to 'term' the moment it earns
        // it — which is how names and Hinglish get in without letting typos in.
        let seen = (try? store.wordCount(normalized)) ?? 1
        try? store.setKind(normalized, hygiene.verdict(for: normalized, seenCount: seen).rawValue)

        lock.lock()
        let prev1 = window.last ?? 0
        let prev2 = window.count >= 2 ? window[window.count - 2] : 0
        window.append(id)
        if window.count > 2 { window.removeFirst(window.count - 2) }
        lock.unlock()

        try? store.recordNgram(prev2: prev2, prev1: prev1, next: id, app: appBundleID ?? "")
    }

    // MARK: - Prediction

    public func suggest(_ context: TypingContext) -> [Candidate] {
        if !context.currentWordPrefix.isEmpty {
            return completions(for: context)
        }
        return nextWords(for: context)
    }

    /// Mid-word: the user has typed a prefix and we offer the rest of the word.
    /// The candidate text is only the *remainder*, since the prefix is already on
    /// screen — which is also what makes `keystrokesSaved` come out right.
    private func completions(for context: TypingContext) -> [Candidate] {
        let prefix = context.currentWordPrefix
        guard prefix.count >= 2 else { return [] }  // one letter is not evidence
        guard let entries = try? store.completions(prefix: PersonalModel.normalize(prefix)) else {
            return []
        }

        let total = max(entries.reduce(0) { $0 + $1.count }, 1)
        return entries.compactMap { entry in
            guard WordHygiene.isOfferable(kind: entry.kind, count: entry.count) else { return nil }
            guard entry.count >= PersonalModel.minimumEvidence else { return nil }
            guard entry.word.count > prefix.count else { return nil }
            let remainder = String(entry.word.dropFirst(prefix.count))
            return Candidate(text: remainder,
                             probability: Double(entry.count) / Double(total),
                             origin: .prefixTrie)
        }
    }

    /// After a separator: predict the next word from context, with backoff.
    private func nextWords(for context: TypingContext) -> [Candidate] {
        let words = PersonalModel.tailWords(of: context.textBeforeCaret, count: 2)
        let prev1 = words.last.flatMap { try? store.vocabID(for: $0) } ?? 0
        let prev2 = words.count >= 2 ? (try? store.vocabID(for: words[0])).flatMap { $0 } ?? 0 : 0
        let app = context.appBundleID ?? ""

        var scored: [String: Double] = [:]

        // Trigram, then bigram, then unigram — each level discounted, and each
        // preferring app-specific evidence over the global aggregate. What you
        // write in Slack is not what you write in Mail.
        let levels: [(prev2: Int64, prev1: Int64, weight: Double)] = [
            (prev2, prev1, 1.0),
            (Store.anyWord, prev1, PersonalModel.backoffFactor),
            (Store.anyWord, Store.anyWord,
             PersonalModel.backoffFactor * PersonalModel.backoffFactor)
        ]

        // App-scoped evidence first, global as the fallback. When there is no
        // frontmost bundle id the two would be the same query, so ask once.
        let scopes = app.isEmpty ? [""] : [app, ""]

        for level in levels {
            // The unigram tier is a last resort: it ignores context entirely, so
            // consulting it while a contextual tier has already answered would
            // let a globally common word outrank one that actually fits.
            if level.prev1 == Store.anyWord && level.prev2 == Store.anyWord
                && !scored.isEmpty { break }
            for scope in scopes {
                guard let rows = try? store.continuations(prev2: level.prev2,
                                                          prev1: level.prev1,
                                                          app: scope),
                      !rows.isEmpty else { continue }
                for row in rows where row.count >= PersonalModel.minimumEvidence {
                    let probability = Double(row.count) / Double(row.contextTotal) * level.weight
                    scored[row.word] = max(scored[row.word] ?? 0, probability)
                }
                break  // app-specific evidence wins outright over the aggregate
            }
            if scored.count >= 5 { break }
        }

        return scored
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { Candidate(text: $0.key + " ", probability: min($0.value, 0.95), origin: .ngram) }
    }

    // MARK: - Helpers

    /// Case is folded for storage so "Thanks" and "thanks" are one word. Casing is
    /// restored at insertion time from what the user actually typed.
    public static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last `count` whole words of a context, normalised.
    public static func tailWords(of text: String, count: Int) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if ContextReader.isWordCharacter(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(normalize(current))
                current = ""
            }
        }
        if !current.isEmpty { words.append(normalize(current)) }
        return Array(words.suffix(count))
    }
}
