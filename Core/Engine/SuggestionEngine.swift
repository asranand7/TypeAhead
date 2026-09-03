import Foundation

/// Turns a typing context into the one suggestion worth showing.
///
/// Pure logic: no AppKit, no event tap, no I/O. That is deliberate — the ranking
/// decisions are the part most worth testing, and they are testable only if they
/// do not need a running app or a focused text field.
///
/// Sources are consulted in registration order and their candidates pooled, then
/// ranked together by expected savings. Every later phase adds itself by
/// registering a source: the n-gram model, snippets, identity, corrections, and
/// finally the LLM all arrive without this file changing.
public final class SuggestionEngine {
    private var sources: [SuggestionSource] = []
    private let ranker: Ranker

    /// Optional, and nil in most tests: with no feedback history it is the
    /// identity function anyway, so requiring one would only add ceremony.
    private let calibrator: Calibrator?

    public init(ranker: Ranker = Ranker(), calibrator: Calibrator? = nil) {
        self.ranker = ranker
        self.calibrator = calibrator
    }

    public func register(_ source: SuggestionSource) {
        sources.append(source)
    }

    public func removeAllSources() {
        sources.removeAll()
    }

    public var registeredSourceNames: [String] {
        sources.map(\.name)
    }

    /// Every candidate from every source, ranked best first.
    public func candidates(for context: TypingContext) -> [Candidate] {
        guard !context.textBeforeCaret.isEmpty || !context.currentWordPrefix.isEmpty else {
            return []
        }
        var pooled = sources
            .flatMap { $0.suggest(context) }
            .filter { !SuggestionEngine.duplicatesTypedText($0, context: context) }
            .compactMap { SuggestionEngine.reconcile($0, with: context) }

        // Before agreement and before ranking: the boost multiplies probabilities,
        // and calibrating afterwards would rescale a number that two sources had
        // already agreed on rather than the evidence each of them brought.
        if let calibrator {
            pooled = pooled.map(calibrator.calibrate)
        }
        return ranker.ranked(SuggestionEngine.boostAgreement(pooled))
    }

    /// Rejects a candidate that merely repeats what the user just typed.
    ///
    /// Belt to the generation guard's braces. A suggestion computed for "Ana" and
    /// shown after "Anand" was typed produces "Anandnd" — visibly wrong, and worse,
    /// it gets learned, so the corruption feeds back into the vocabulary. The
    /// generation counter should stop that happening at all; this makes certain
    /// that if one ever slips through, it cannot be shown.
    public static func duplicatesTypedText(_ candidate: Candidate, context: TypingContext) -> Bool {
        guard candidate.replacesPreviousCharacters == 0 else { return false }
        let insertion = candidate.text.trimmingCharacters(in: .whitespaces).lowercased()
        guard insertion.count >= 2 else { return false }
        return context.currentWordPrefix.lowercased().hasSuffix(insertion)
    }

    /// Reconciles a completion with the text the caret is sitting in front of.
    ///
    /// Every source works from the prefix alone, so with the caret inside
    /// `recei|ving` they all propose completions of "recei" — and inserting one
    /// gives "receivedving". The word was never half-typed; it was finished, and
    /// the caret merely happens to be in the middle of it.
    ///
    /// Rather than suppress those outright, this completes *through* the tail
    /// where it can:
    ///
    ///   - caret at a word boundary — nothing to reconcile, pass it through
    ///   - candidate ends with the tail — trim the tail and offer the difference,
    ///     so "recei|ng" with candidate "ving" offers "vi"
    ///   - candidate is exactly the tail — the word is already what the candidate
    ///     would make it; there is nothing to add
    ///   - anything else — inserting would corrupt the word, so drop it
    ///
    /// Corrections are dropped whenever the caret is inside a word: they delete
    /// backwards from the caret and would leave the tail stranded against the
    /// replacement.
    public static func reconcile(_ candidate: Candidate,
                                 with context: TypingContext) -> Candidate? {
        let tail = context.currentWordSuffix
        guard !tail.isEmpty else { return candidate }
        guard candidate.replacesPreviousCharacters == 0 else { return nil }
        guard candidate.text.hasSuffix(tail) else { return nil }

        let trimmed = String(candidate.text.dropLast(tail.count))
        guard !trimmed.isEmpty else { return nil }
        return Candidate(text: trimmed,
                         probability: candidate.probability,
                         origin: candidate.origin,
                         replacesPreviousCharacters: 0,
                         granularity: candidate.granularity)
    }

    /// Raises confidence where independent sources agree.
    ///
    /// The dictionary knows which words exist, the model knows which one fits the
    /// sentence, and personal memory knows which one this person writes. When two
    /// of them independently land on the same text that is much stronger evidence
    /// than either alone — and, more usefully, it lets a grammatically correct
    /// choice overtake a merely frequent one without either source having to know
    /// the other exists.
    ///
    /// Duplicates are collapsed at the same time, so the same suggestion cannot
    /// occupy two slots.
    public static func boostAgreement(_ candidates: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        var origins: [String: Set<CandidateOrigin>] = [:]

        for candidate in candidates {
            let key = candidate.text.lowercased()
            origins[key, default: []].insert(candidate.origin)
            if let existing = best[key], existing.probability >= candidate.probability { continue }
            best[key] = candidate
        }

        return best.map { key, candidate in
            let agreeing = origins[key]?.count ?? 1
            guard agreeing > 1 else { return candidate }
            // Each additional independent source is worth a meaningful lift, but
            // confidence stays short of certainty — agreement between two fallible
            // sources is not proof.
            let boosted = min(0.95, candidate.probability * (1.0 + 0.6 * Double(agreeing - 1)))
            return Candidate(text: candidate.text,
                             probability: boosted,
                             origin: candidate.origin,
                             replacesPreviousCharacters: candidate.replacesPreviousCharacters,
                             // Carried explicitly. Omitting it fell back to the
                             // origin's default, so a candidate whose granularity
                             // had been set deliberately lost it on the way
                             // through agreement — changing how many Tabs it takes.
                             granularity: candidate.granularity)
        }
    }

    /// The single suggestion to show, or nil when nothing clears the savings gate.
    public func bestCandidate(for context: TypingContext) -> Candidate? {
        candidates(for: context).first
    }
}
