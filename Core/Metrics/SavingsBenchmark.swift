import Foundation

/// Replays text through the engine and reports how many keystrokes it would have
/// saved.
///
/// This is the plan's primary measure, and the only honest way to compare two
/// configurations: acceptance rate flatters short suggestions, and raw accuracy
/// ignores how much a suggestion was worth. Keystrokes saved is what the user
/// actually experiences.
///
/// The simulated typist accepts a suggestion whenever it is genuinely correct —
/// exactly a prefix of what comes next — and types a character otherwise. That is
/// an upper bound on a real person, who misses some, but it is the same upper
/// bound for every configuration, so comparisons hold.
public struct SavingsBenchmark {
    public struct Result {
        public let charactersTyped: Int
        public let keystrokesUsed: Int
        public let suggestionsAccepted: Int
        public let acceptedByOrigin: [CandidateOrigin: Int]

        /// Percentage of keystrokes avoided. The headline number.
        public var percentSaved: Double {
            guard charactersTyped > 0 else { return 0 }
            return (1.0 - Double(keystrokesUsed) / Double(charactersTyped)) * 100
        }
    }

    private let engine: SuggestionEngine

    public init(engine: SuggestionEngine) {
        self.engine = engine
    }

    public func replay(_ text: String, appBundleID: String? = nil) -> Result {
        let characters = Array(text)
        var position = 0
        var keystrokes = 0
        var accepted = 0
        var byOrigin: [CandidateOrigin: Int] = [:]

        while position < characters.count {
            let typed = String(characters[0..<position])
            let context = TypingContext(
                textBeforeCaret: String(typed.suffix(ContextReader.maxContextChars)),
                currentWordPrefix: ContextReader.trailingWord(of: typed),
                appBundleID: appBundleID,
                isAuthoritative: true)

            if let candidate = engine.bestCandidate(for: context),
               candidate.replacesPreviousCharacters == 0,
               !candidate.text.isEmpty {
                let remaining = String(characters[position...])
                if remaining.hasPrefix(candidate.text) {
                    // One Tab replaces the whole suggestion.
                    position += candidate.text.count
                    keystrokes += 1
                    accepted += 1
                    byOrigin[candidate.origin, default: 0] += 1
                    continue
                }
            }

            position += 1
            keystrokes += 1
        }

        return Result(charactersTyped: characters.count,
                      keystrokesUsed: keystrokes,
                      suggestionsAccepted: accepted,
                      acceptedByOrigin: byOrigin)
    }

    /// Feeds the text through observers first, so the benchmark measures a model
    /// that has actually seen the user's writing rather than a cold one.
    public static func train(_ observers: [TypingObserver],
                             on text: String,
                             appBundleID: String? = nil) {
        // Mirrors `Coordinator.accumulate` exactly, boundary classification
        // included. A benchmark that fed the observers a different signal stream
        // from the live app would be measuring something the user never runs.
        var current = ""
        for character in text {
            if let scalar = character.unicodeScalars.first,
               ContextReader.isWordCharacter(scalar) {
                current.append(character)
                for observer in observers { observer.observe(.typed(String(character))) }
            } else {
                let boundary = TextBoundary(separator: character)
                if current.isEmpty {
                    if boundary.endsSentence {
                        for observer in observers { observer.observe(.boundaryCrossed(boundary)) }
                    }
                } else {
                    for observer in observers {
                        observer.observe(.wordCommitted(word: current,
                                                        boundary: boundary,
                                                        appBundleID: appBundleID))
                    }
                    current = ""
                }
                for observer in observers { observer.observe(.typed(String(character))) }
            }
        }
        if !current.isEmpty {
            for observer in observers {
                observer.observe(.wordCommitted(word: current,
                                                boundary: .none,
                                                appBundleID: appBundleID))
            }
        }
    }
}

/// Side-by-side comparison of two models on the user's own writing.
///
/// Replaces judging a model by reputation. The question is not which model is
/// better in general — it is which one saves *this person* more keystrokes on
/// *their* text, at a latency they will tolerate.
public struct ModelComparison {
    public struct Row {
        public let modelName: String
        public let percentSaved: Double
        public let medianLatencyMillis: Double
    }

    public static func compare(sources: [SuggestionSource],
                               baseline: [SuggestionSource],
                               corpus: String) -> [Row] {
        sources.map { source in
            let engine = SuggestionEngine()
            for base in baseline { engine.register(base) }
            engine.register(source)

            var latencies: [Double] = []
            let sampleContext = TypingContext(
                textBeforeCaret: String(corpus.prefix(120)),
                currentWordPrefix: "",
                appBundleID: nil,
                isAuthoritative: true)
            for _ in 0..<20 {
                let start = DispatchTime.now()
                _ = source.suggest(sampleContext)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
                latencies.append(elapsed / 1_000_000)
            }
            latencies.sort()

            let result = SavingsBenchmark(engine: engine).replay(corpus)
            return Row(modelName: source.name,
                       percentSaved: result.percentSaved,
                       medianLatencyMillis: latencies[latencies.count / 2])
        }
    }
}
