import Foundation

/// Prediction quality, measured the way the literature measures it.
///
/// `SavingsBenchmark` answers "how many keystrokes would this have saved",
/// which is the right headline number and the wrong diagnostic: it conflates how
/// often the app speaks with how often it is right, and it cannot be compared to
/// anything outside this repository. Smart Compose reported log perplexity and
/// ExactMatch@N, and both are worth having here for the same reasons they were
/// worth having there.
///
/// **Coverage has to be held constant for any of this to mean anything.** A
/// model that only ever suggests "the" scores brilliantly on precision and is
/// useless; one that suggests constantly scores badly and may still be better.
/// Every result below carries its trigger rate, and two configurations are only
/// comparable at similar coverage.
public struct PredictionMetrics {

    // MARK: - ExactMatch@N

    public struct ExactMatch {
        /// Word boundaries where the engine offered anything at all.
        public let triggered: Int
        /// Boundaries considered.
        public let opportunities: Int
        /// Triggered suggestions whose first N words matched the truth exactly.
        public let matched: Int

        /// How often the app speaks. Meaningless alone, essential alongside
        /// `precision` — the two move against each other.
        public var coverage: Double {
            opportunities > 0 ? Double(triggered) / Double(opportunities) : 0
        }

        /// How often it is right when it speaks.
        public var precision: Double {
            triggered > 0 ? Double(matched) / Double(triggered) : 0
        }
    }

    /// Fraction of offered suggestions whose first `words` words are exactly what
    /// the user went on to type.
    ///
    /// Exact, not fuzzy, and case-insensitively compared only on the words
    /// themselves. A suggestion that is close but not identical costs the user a
    /// correction, which is worse than having said nothing, so partial credit
    /// would flatter the wrong behaviour.
    public static func exactMatch(engine: SuggestionEngine,
                                  on text: String,
                                  words: Int = 1,
                                  appBundleID: String? = nil) -> ExactMatch {
        var triggered = 0, matched = 0, opportunities = 0

        for boundary in wordBoundaries(in: text) {
            opportunities += 1
            let before = String(text.prefix(boundary))
            let context = TypingContext(
                textBeforeCaret: String(before.suffix(ContextReader.maxContextChars)),
                currentWordPrefix: ContextReader.trailingWord(of: before),
                appBundleID: appBundleID,
                isAuthoritative: true)

            guard let candidate = engine.bestCandidate(for: context),
                  candidate.replacesPreviousCharacters == 0 else { continue }
            triggered += 1

            let predicted = normalizedWords(candidate.text).prefix(words)
            let truth = normalizedWords(String(text.dropFirst(boundary))).prefix(words)
            guard !predicted.isEmpty, predicted.count == truth.count else { continue }
            if Array(predicted) == Array(truth) { matched += 1 }
        }
        return ExactMatch(triggered: triggered,
                          opportunities: opportunities,
                          matched: matched)
    }

    // MARK: - Perplexity

    public struct Perplexity {
        public let logProbability: Double
        public let tokens: Int
        /// Mean negative log probability per token. Lower is better; comparable
        /// across configurations only on the same text.
        public var logPerplexity: Double {
            tokens > 0 ? -logProbability / Double(tokens) : .infinity
        }
        public var perplexity: Double { exp(logPerplexity) }
    }

    /// Log perplexity of `text` under a next-word distribution.
    ///
    /// The measure that says whether the *model* improved, independent of the
    /// ranker, the savings gate and every threshold — all of which can make
    /// suggestions look better by making them rarer. A change that lowers
    /// perplexity has made the prediction better; a change that only moves
    /// keystrokes saved may have moved a threshold.
    ///
    /// Unseen words are charged `floor` rather than infinity. The personal model
    /// is sparse by construction and will always meet words it has never seen;
    /// scoring those as impossible would make every result infinite and measure
    /// nothing.
    public static func perplexity(of text: String,
                                  distribution: (TypingContext) -> [String: Double],
                                  appBundleID: String? = nil,
                                  floor: Double = 1e-6) -> Perplexity {
        var total = 0.0
        var counted = 0

        for boundary in wordBoundaries(in: text) {
            let before = String(text.prefix(boundary))
            // Only score positions where a whole word is about to begin: a
            // distribution over next *words* says nothing about the middle of one.
            guard ContextReader.trailingWord(of: before).isEmpty else { continue }
            guard let truth = normalizedWords(String(text.dropFirst(boundary))).first
            else { continue }

            let context = TypingContext(
                textBeforeCaret: String(before.suffix(ContextReader.maxContextChars)),
                currentWordPrefix: "",
                appBundleID: appBundleID,
                isAuthoritative: true)

            let scores = Fusion.normalized(distribution(context))
            total += log(max(scores[truth] ?? 0, floor))
            counted += 1
        }
        return Perplexity(logProbability: total, tokens: counted)
    }

    // MARK: - Helpers

    /// Offsets where a suggestion could be offered: after every separator, and
    /// after every character of a partially typed word.
    ///
    /// Every position a real user's caret passes through, so coverage means what
    /// it sounds like rather than being computed over a convenient subset.
    public static func wordBoundaries(in text: String) -> [Int] {
        Array(1..<max(text.count, 1))
    }

    /// Words of a string, case-folded, with punctuation stripped — the form two
    /// pieces of text have to be reduced to before "exactly matches" is a fair
    /// question. Without it "update" and "update." never match and every
    /// sentence-final prediction is scored wrong.
    public static func normalizedWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if ContextReader.isWordCharacter(scalar) {
                current.append(character)
            } else if !current.isEmpty {
                out.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { out.append(current.lowercased()) }
        return out
    }
}
