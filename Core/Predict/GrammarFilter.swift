import Foundation
import NaturalLanguage

/// Picks the right inflection using the word before the caret.
///
/// The dictionary is frequency-ordered and grammar-blind: it offers "considering"
/// for "conside" whether you wrote "I am conside" or "I will conside". The first
/// is right and the second is wrong, and no amount of frequency data can tell
/// them apart.
///
/// The model would know, but it cannot be asked — a prompt that stops mid-token
/// comes back corrupted ("I am conside" returns "ing", dropping the r).
///
/// So the analysis is Apple's, not hand-rolled: `NLTagger` gives real
/// part-of-speech tags and lemmas on device, in about 0.03ms. Suffix rules were
/// the first attempt and were wrong in the usual ways — "during" is not a verb in
/// the progressive, "bed" is not a past participle. A lemma comparison is the
/// question actually being asked: is this word the same word as its base form, or
/// an inflection of it?
///
/// Deliberately a *reweighting*, never a veto. These rules are correct far more
/// often than not, but English is not a lookup table, and suppressing a candidate
/// outright would turn every exception into a missing suggestion.
public enum GrammarFilter {
    /// Modals and infinitive markers: the verb that follows is the bare stem.
    /// "I will consider", never "I will considering".
    private static let requiresBaseForm: Set<String> = [
        "will", "would", "can", "could", "shall", "should", "may", "might",
        "must", "to", "please", "let", "lets", "don't", "doesn't", "didn't",
        "do", "does", "did", "cannot", "won't", "help"
    ]

    /// Forms of "to be": the verb that follows takes -ing.
    /// "I am considering", never "I am consider".
    private static let requiresProgressive: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being", "keep", "keeps",
        "started", "start", "stop", "stopped", "while", "currently"
    ]

    /// Forms of "to have": the verb that follows is a past participle.
    /// "I have considered", never "I have consider".
    private static let requiresPastParticiple: Set<String> = [
        "have", "has", "had", "having", "been"
    ]

    // Determiners are not listed: NLTagger identifies them, which covers every
    // determiner in the language rather than the two dozen anyone remembers.

    /// One tagger, reused. Creating one per keystroke is what makes linguistic
    /// analysis look expensive when it is not.
    private static let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    private static let taggerLock = NSLock()

    private static let boost = 2.2
    private static let penalty = 0.35

    /// Reweights `candidates` for the word completed by `prefix`, given `context`.
    public static func adjust(_ candidates: [Candidate],
                              prefix: String,
                              context: String) -> [Candidate] {
        guard let expected = expectedForm(in: context, before: prefix) else {
            return candidates
        }

        return candidates.map { candidate in
            let whole = prefix + candidate.text
            let multiplier: Double
            switch form(of: whole) {
            case expected: multiplier = boost
            case .unknown: multiplier = 1.0
            default: multiplier = penalty
            }
            return Candidate(text: candidate.text,
                             probability: min(0.95, candidate.probability * multiplier),
                             origin: candidate.origin,
                             replacesPreviousCharacters: candidate.replacesPreviousCharacters)
        }
    }

    /// The grammatical form the word being typed is required to take, or nil when
    /// the preceding word imposes nothing.
    ///
    /// Split out of `adjust` so callers can ask the cheaper question "does the
    /// grammar pin this down at all?" — which is what lets a two-character prefix
    /// be completed when it would otherwise be a coin flip.
    public static func expectedForm(in context: String, before prefix: String) -> Form? {
        guard let previous = precedingWord(in: context, before: prefix) else { return nil }
        if requiresBaseForm.contains(previous) { return .base }
        if requiresProgressive.contains(previous) { return .progressive }
        if requiresPastParticiple.contains(previous) { return .pastParticiple }
        if partOfSpeech(of: previous, in: context) == .determiner { return .noun }
        return nil
    }

    public enum Form { case base, progressive, pastParticiple, noun, unknown }

    /// Which form a word is in, from its lemma and its part of speech.
    ///
    /// The lemma is what makes this reliable. "during" ends in -ing but its lemma
    /// is "during" — it is not an inflection of anything, so it is not progressive.
    /// A suffix rule cannot see that difference; a lemma comparison gets it for
    /// free.
    public static func form(of word: String) -> Form {
        let lower = word.lowercased()
        guard lower.count >= 3 else { return .unknown }

        taggerLock.lock()
        defer { taggerLock.unlock() }

        tagger.string = lower
        let start = lower.startIndex
        let lemma = tagger.tag(at: start, unit: .word, scheme: .lemma).0?.rawValue
        let lexical = tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0

        // Tagged a noun and unchanged from its lemma: a noun, whatever it ends in.
        if lexical == .noun, lemma == nil || lemma == lower { return .noun }

        // An inflection differs from its base form. That, not the ending, is what
        // makes it an inflection.
        if let lemma, lemma != lower {
            if lower.hasSuffix("ing") { return .progressive }
            if lower.hasSuffix("ed") || lower.hasSuffix("en") { return .pastParticiple }
            return .noun     // recommendation → recommend: a derived noun
        }

        if lexical == .verb { return .base }
        if lexical == .noun { return .noun }

        // A guess, and knowingly so. `NLTagger` returns `OtherWord` with no lemma
        // for a bare "consider" *and* a bare "considerable"; given the sentence
        // it calls both verbs, because it is reading the slot after "will"
        // rather than the word. There is no signal here to separate them, so
        // this stays a length heuristic rather than pretending to more. What
        // keeps it from mattering is upstream: the candidate list is only
        // widened past the frequent handful when a hard filter is available to
        // narrow it again.
        return lower.count >= 4 ? .base : .unknown
    }

    /// The part of speech of `word` as it appears in `sentence` — in context, so
    /// "the" is a determiner and "that" is judged by how it is being used.
    public static func partOfSpeech(of word: String, in sentence: String) -> NLTag? {
        taggerLock.lock()
        defer { taggerLock.unlock() }
        tagger.string = sentence
        guard let range = sentence.range(of: word, options: [.caseInsensitive, .backwards])
        else { return nil }
        return tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
    }

    /// The completed word immediately before the one being typed, or nil when a
    /// sentence boundary sits between them.
    ///
    /// The boundary check is what stops a constraint leaking across a full stop.
    /// Splitting on non-letters discards punctuation along with spaces, so
    /// "Let me know if you can. Regar…" reported "can" as the preceding word and
    /// the filter dutifully demanded a base-form verb for a word that starts a
    /// new sentence. Nothing before a full stop governs anything after it.
    public static func precedingWord(in context: String, before prefix: String) -> String? {
        var text = context
        // Drop the partial word so the *previous* one is found, not this one.
        if !prefix.isEmpty, text.lowercased().hasSuffix(prefix.lowercased()) {
            text = String(text.dropLast(prefix.count))
        }
        guard let last = PersonalModel.tokens(of: text).last,
              !PersonalModel.BoundaryToken.isBoundary(last) else { return nil }
        return last
    }
}
