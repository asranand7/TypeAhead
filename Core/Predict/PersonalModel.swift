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
    public static let minimumEvidence = 2

    private let store: Store
    private let hygiene: WordHygiene
    private let lock = NSLock()

    /// The last two committed word ids, oldest first. Reset whenever the caret
    /// moves somewhere we did not put it, because the preceding words are then
    /// unknown and a trigram built across the gap would be fiction.
    private var window: [Int64] = []

    /// A sentence or paragraph token waiting to be pushed, held until the next
    /// word arrives.
    ///
    /// Deferred rather than pushed on the spot because a separator *run* has to
    /// settle first: "world.\n\n" is one break, not two, and pushing on the full
    /// stop would record a sentence token that the newlines then have to
    /// contradict. Holding it costs nothing — the token is only needed as
    /// context for the word that follows, which is exactly when it is released.
    private var pendingBoundary: String?

    /// The sequence tokens standing in for sentence and paragraph breaks.
    ///
    /// Prefixed with U+0001 so they cannot collide with anything typed: a control
    /// character is never a word character, so no real token can reach this form.
    /// Stored in `vocab` like any other word, which means backoff, per-app
    /// scoping and the existing queries all work on them unchanged — the model
    /// learns what starts your sentences the same way it learns anything else.
    public enum BoundaryToken {
        public static let sentence = "\u{1}s"
        public static let paragraph = "\u{1}p"

        public static func forBoundary(_ boundary: TextBoundary) -> String? {
            switch boundary {
            case .paragraph: return paragraph
            case .sentence:  return sentence
            default:         return nil
            }
        }

        public static func isBoundary(_ token: String) -> Bool {
            token == sentence || token == paragraph
        }

        /// A paragraph break subsumes a sentence break in the same run.
        public static func stronger(_ a: String?, _ b: String?) -> String? {
            if a == paragraph || b == paragraph { return paragraph }
            return a ?? b
        }
    }

    public init(store: Store, hygiene: WordHygiene = WordHygiene()) {
        self.store = store
        self.hygiene = hygiene
    }

    // MARK: - Learning

    public func observe(_ signal: TypingSignal) {
        switch signal {
        case .wordCommitted(let word, let boundary, let bundleID):
            learn(word: word, boundary: boundary, appBundleID: bundleID)

        case .boundaryCrossed(let boundary):
            // Upgrades a break already pending rather than adding to it, so a
            // run of separators stays one boundary however it is spelled.
            lock.lock()
            pendingBoundary = BoundaryToken.stronger(
                pendingBoundary, BoundaryToken.forBoundary(boundary))
            lock.unlock()

        case .caretMoved:
            lock.lock()
            window.removeAll()
            pendingBoundary = nil
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

    private func learn(word: String, boundary: TextBoundary, appBundleID: String?) {
        let normalized = PersonalModel.normalize(word)
        guard !normalized.isEmpty else { return }

        // A break held over from the previous word is released first, so the
        // sequence the model learns is exactly the sequence `tokens(of:)` will
        // reconstruct from the document at prediction time. The two have to agree
        // token for token or the context looked up is not the context recorded.
        lock.lock()
        let released = pendingBoundary
        pendingBoundary = nil
        lock.unlock()
        if let released { push(token: released, app: appBundleID ?? "", classify: false) }

        push(token: normalized, app: appBundleID ?? "", classify: true)

        // A word ended by a full stop arms the next break. Held, not pushed:
        // newlines may still follow and turn it into a paragraph.
        if let token = BoundaryToken.forBoundary(boundary) {
            lock.lock()
            pendingBoundary = BoundaryToken.stronger(pendingBoundary, token)
            lock.unlock()
        }

        // A word flushed with no separator at all — a caret move, a focus change —
        // has nothing after it we can vouch for, so the window is cut rather than
        // left to glue this word onto whatever is typed next.
        if boundary == .none {
            lock.lock()
            window.removeAll()
            pendingBoundary = nil
            lock.unlock()
        }
    }

    /// Records one token in the sequence and advances the context window.
    ///
    /// - Parameter classify: false for boundary tokens, which are not words and
    ///   must never be run past `WordHygiene` — it would judge them fragments and
    ///   mark them unverified, and an unverified token is never offered, which is
    ///   correct but for the wrong reason and would break the moment the rule
    ///   changed. They are sequence markers, and carry no kind.
    private func push(token: String, app: String, classify: Bool) {
        guard let id = try? store.recordWord(token) else { return }

        if classify {
            // Re-classified on every sighting, so an unrecognised word that keeps
            // recurring is promoted from 'unverified' to 'term' the moment it earns
            // it — which is how names and Hinglish get in without letting typos in.
            let seen = (try? store.wordCount(token)) ?? 1
            try? store.setKind(token, hygiene.verdict(for: token, seenCount: seen).rawValue)
        } else {
            // Marks the row as machinery rather than vocabulary. It is what keeps
            // sequence markers out of the memory review, the export and the word
            // count — surfaces that promise the user their own words — and
            // `WordHygiene.isOfferable` rejects the kind outright, so a marker can
            // never be offered as a completion either.
            try? store.setKind(token, Store.boundaryKind)
        }

        lock.lock()
        let prev1 = window.last ?? 0
        let prev2 = window.count >= 2 ? window[window.count - 2] : 0
        window.append(id)
        if window.count > 2 { window.removeFirst(window.count - 2) }
        lock.unlock()

        try? store.recordNgram(prev2: prev2, prev1: prev1, next: id, app: app)
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
        let scored = nextWordDistribution(for: context)
        let lead = PersonalModel.leadingSeparator(for: context.textBeforeCaret)
        let capitalize = PersonalModel.startsSentence(context.textBeforeCaret)
        return PersonalModel.candidates(from: scored,
                                        lead: lead,
                                        capitalize: capitalize,
                                        origin: .ngram)
    }

    /// Turns a scored word distribution into ranked candidates, carrying the
    /// separator and casing the caret position calls for.
    ///
    /// Shared with `Fusion`, so a fused distribution is rendered into text by
    /// exactly the same rules as an unfused one — the interpolation changes which
    /// word wins, never how a winning word is spelled or spaced.
    static func candidates(from scored: [String: Double],
                           lead: String,
                           capitalize: Bool,
                           origin: CandidateOrigin) -> [Candidate] {
        scored
            .sorted { $0.value > $1.value }
            .lazy
            // A boundary token is a marker in the sequence, not something anyone
            // types. It is legitimate context and a legitimate prediction — the
            // model genuinely knows a sentence is about to end — but there is no
            // text to insert for it, so it can never be a candidate.
            .filter { !BoundaryToken.isBoundary($0.key) }
            .prefix(5)
            .map { entry in
                let word = capitalize ? PersonalModel.capitalized(entry.key) : entry.key
                return Candidate(text: lead + word + " ",
                                 probability: min(entry.value, 0.95),
                                 origin: origin)
            }
    }

    /// What personal memory believes comes next, as a distribution over words.
    ///
    /// Exposed separately from `suggest` because `Fusion` needs the numbers, not
    /// the rendered candidates: interpolating against a global model means
    /// looking up this model's probability for a word *it* did not propose, which
    /// a list of top-5 candidates cannot answer.
    /// - Parameter minimumEvidence: how many sightings a continuation needs
    ///   before it is included. The default is the standalone bar: a suggestion
    ///   shown on the strength of personal memory alone should rest on more than
    ///   one observation.
    ///
    ///   `Fusion` lowers it to one, and the distinction matters. Inside an
    ///   interpolation a single sighting is not a claim, it is a prior on a model
    ///   that is fluent anyway — and holding it back is worst exactly where
    ///   personal memory is most valuable. Measured: with the standalone bar
    ///   applied, "Please find attached the" fused to "original", because
    ///   "report", "invoice" and "agenda" had been seen once each and were
    ///   filtered out before the model ever saw them.
    public func nextWordDistribution(for context: TypingContext,
                                     minimumEvidence: Int = PersonalModel.minimumEvidence)
        -> [String: Double] {
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
                for row in rows where row.count >= minimumEvidence {
                    let probability = Double(row.count) / Double(row.contextTotal) * level.weight
                    scored[row.word] = max(scored[row.word] ?? 0, probability)
                }
                break  // app-specific evidence wins outright over the aggregate
            }
            if scored.count >= 5 { break }
        }

        return scored
    }

    /// The separator a suggestion has to carry in front of it.
    ///
    /// Every source produces the word alone, and the caret is not always sitting
    /// after a space. Pause after a comma and the old behaviour inserted
    /// "Hi John," + "thanks " = "Hi John,thanks" — the suggestion welded to the
    /// punctuation. A break that already ends in whitespace needs nothing; a bare
    /// one needs the space the user has not typed yet.
    public static func leadingSeparator(for text: String) -> String {
        guard let last = text.last else { return "" }
        if last.isWhitespace { return "" }
        return ContextReader.isWordCharacter(last.unicodeScalars.first!) ? "" : " "
    }

    /// Whether the caret sits where a capital letter belongs.
    ///
    /// Storage folds case so "Thanks" and "thanks" are one word, which is right
    /// for counting and wrong for inserting: at the start of a line the model
    /// knew the word and offered it in lower case. True at the very start of a
    /// field and after any sentence or paragraph break.
    public static func startsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return BoundaryToken.isBoundary(tokens(of: text).last ?? "")
    }

    /// Upper-cases the first character and leaves the rest alone, so an acronym
    /// or a deliberately lower-case name is not rewritten past its first letter.
    public static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Helpers

    /// Case is folded for storage so "Thanks" and "thanks" are one word. Casing is
    /// restored at insertion time from what the user actually typed.
    public static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last `count` tokens of a context — words and boundary markers alike.
    public static func tailWords(of text: String, count: Int) -> [String] {
        Array(tokens(of: text).suffix(count))
    }

    /// The token sequence a stretch of text represents, as the model sees it.
    ///
    /// This is the counterpart of `learn`, and the two must agree exactly: the
    /// context looked up at prediction time has to be the context that was
    /// recorded at learning time, or the trigram is a query for a row nobody
    /// ever wrote. Learning builds the sequence from typed separators, this
    /// rebuilds it from the finished document, and both produce
    /// `[…, "john", "\u{1}p", "thanks"]` for "Hi John,\n\nThanks".
    ///
    /// The previous version dropped every separator, so "Sounds good. Thanks"
    /// and "Sounds good Thanks" were the same context and no sentence boundary
    /// existed anywhere in the model.
    public static func tokens(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var pending: String?

        func flushWord() {
            guard !current.isEmpty else { return }
            out.append(normalize(current))
            current = ""
        }
        func flushBoundary() {
            if let pending { out.append(pending) }
            pending = nil
        }

        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if ContextReader.isWordCharacter(scalar) {
                // A word after a run of separators closes that run.
                flushBoundary()
                current.append(character)
            } else {
                flushWord()
                // Strongest break in the run wins: ".\n\n" is one paragraph
                // boundary, not a sentence boundary followed by two paragraphs.
                pending = BoundaryToken.stronger(
                    pending, BoundaryToken.forBoundary(TextBoundary(separator: character)))
            }
        }
        flushWord()
        flushBoundary()
        return out
    }
}
