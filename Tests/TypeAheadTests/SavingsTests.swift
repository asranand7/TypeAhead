import Carbon.HIToolbox
import CoreGraphics
import Foundation
import TypeAheadCore

/// Stands in for a loaded model. Deliberately not a real one: rule 2 says the app
/// must not care which model is attached, and a test that needs a 600 MB download
/// would prove the opposite.
final class FakeModel: SuggestionSource {
    let name: String
    private let reply: String

    init(name: String, reply: String) {
        self.name = name
        self.reply = reply
    }

    func suggest(_ context: TypingContext) -> [Candidate] {
        [Candidate(text: reply, probability: 0.4, origin: .model)]
    }
}

func runSavingsTests(_ s: Suite) {
    s.report("Keystrokes saved")

    // Real prose, and a split. `Corpus.train` is what the model learns from;
    // `Corpus.test` is different messages in the same voice, which is the only
    // way to find out whether anything generalises.
    let corpus = Corpus.train

    s.test("replaying held-out writing saves a meaningful share of keystrokes") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        let miner = SnippetMiner(store: store)
        let snippets = SnippetSource(store: store)

        SavingsBenchmark.train([personal, miner], on: Corpus.train)

        let engine = SuggestionEngine()
        engine.register(snippets)
        engine.register(personal)

        let result = SavingsBenchmark(engine: engine).replay(Corpus.test)
        let byOrigin = result.acceptedByOrigin
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \($0.value)" }
            .joined(separator: ", ")
        s.report(String(format: "    → %.1f%% saved (%d of %d keystrokes; %@)",
                        result.percentSaved,
                        result.charactersTyped - result.keystrokesUsed,
                        result.charactersTyped,
                        byOrigin))
        // Lower than the old number, and the old number was fiction: it measured
        // replay of the training text itself. This is held-out writing.
        s.expect(result.percentSaved > 12,
                 "saved \(String(format: "%.1f", result.percentSaved))% — expected more than 12%")
        s.expect(result.keystrokesUsed < result.charactersTyped,
                 "fewer keystrokes than characters")
    }

    s.report("Prediction quality")

    s.test("ExactMatch@1 and coverage on held-out writing") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        let miner = SnippetMiner(store: store)
        SavingsBenchmark.train([personal, miner], on: Corpus.train)

        let engine = SuggestionEngine()
        engine.register(SnippetSource(store: store))
        engine.register(personal)

        let match = PredictionMetrics.exactMatch(engine: engine, on: Corpus.test, words: 1)
        s.report(String(format: "    → ExactMatch@1 %.1f%% at %.1f%% coverage (%d of %d offered)",
                        match.precision * 100, match.coverage * 100,
                        match.matched, match.triggered))
        s.expect(match.triggered > 0, "the engine offered something on held-out text")
        // Compared against always guessing the single most frequent word, which is
        // the bar any predictor has to clear to be worth its screen space.
        s.expect(match.precision > 0.2,
                 "ExactMatch@1 \(String(format: "%.2f", match.precision)) — expected above 0.20")
    }

    s.test("boundary tokens lower perplexity on held-out writing") {
        // The measurement that says the punctuation work was worth doing, rather
        // than merely that it did not break anything: a model that knows where
        // sentences end should be less surprised by the next word than one that
        // does not. Both halves see the same text and the same split.
        let (aware, _) = try makeTemporaryStore()
        let withBoundaries = PersonalModel(store: aware)
        SavingsBenchmark.train([withBoundaries], on: Corpus.train)

        let (flat, _) = try makeTemporaryStore()
        let withoutBoundaries = PersonalModel(store: flat)
        // Every separator reported as a plain space — the old behaviour exactly.
        for word in PredictionMetrics.normalizedWords(Corpus.train) {
            withoutBoundaries.observe(
                .wordCommitted(word: word, boundary: .space, appBundleID: nil))
        }

        let scored = PredictionMetrics.perplexity(
            of: Corpus.test, distribution: { withBoundaries.nextWordDistribution(for: $0) })
        let baseline = PredictionMetrics.perplexity(
            of: Corpus.test, distribution: { withoutBoundaries.nextWordDistribution(for: $0) })

        s.report(String(format: "    → log-perplexity %.3f with boundaries, %.3f without",
                        scored.logPerplexity, baseline.logPerplexity))
        s.expect(scored.tokens > 0, "scored some positions")
        s.expect(scored.logPerplexity < baseline.logPerplexity,
                 "boundary-aware model should be less surprised — "
                 + "\(String(format: "%.3f", scored.logPerplexity)) vs "
                 + "\(String(format: "%.3f", baseline.logPerplexity))")
    }

    s.report("Fusion")

    s.test("interpolation keeps words only one side knows") {
        // The union, not the intersection: a name only memory has seen and a
        // common word only the model proposed must both survive.
        let fused = Fusion.interpolate(personal: ["chaudhary": 1.0],
                                       global: ["the": 1.0],
                                       personalWeight: 0.4)
        s.expectClose(fused["chaudhary"] ?? 0, 0.4, "personal-only word keeps alpha")
        s.expectClose(fused["the"] ?? 0, 0.6, "model-only word keeps 1 - alpha")
    }

    s.test("agreement beats either source alone") {
        let fused = Fusion.interpolate(personal: ["review": 0.5, "reply": 0.5],
                                       global: ["review": 0.5, "report": 0.5],
                                       personalWeight: 0.4)
        let agreed = fused["review"] ?? 0
        s.expect(agreed > fused["reply"] ?? 0, "agreed word beats personal-only")
        s.expect(agreed > fused["report"] ?? 0, "agreed word beats model-only")
    }

    s.test("an empty side leaves the other untouched") {
        // Rule 2 in arithmetic: with no model, fusion has to be the identity on
        // personal memory or removing the model would silently change ranking.
        let fused = Fusion.interpolate(personal: ["thanks": 0.75, "please": 0.25],
                                       global: [:],
                                       personalWeight: 0.4)
        s.expectClose(fused["thanks"] ?? 0, 0.4 * 0.75, "personal share preserved")
        s.expect((fused["thanks"] ?? 0) > (fused["please"] ?? 0), "ordering preserved")
    }

    s.test("memory alone beats no memory") {
        // The comparison that justifies the whole personal-model half of the design.
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        SavingsBenchmark.train([personal], on: corpus)

        let trained = SuggestionEngine()
        trained.register(personal)

        let (emptyStore, _) = try makeTemporaryStore()
        let cold = SuggestionEngine()
        cold.register(PersonalModel(store: emptyStore))

        let withMemory = SavingsBenchmark(engine: trained).replay(corpus)
        let without = SavingsBenchmark(engine: cold).replay(corpus)

        s.expectEqual(without.percentSaved, 0, "a cold model saves nothing")
        s.expect(withMemory.percentSaved > without.percentSaved, "learning pays")
    }

    s.report("Rule 2 — the model is a commodity")

    s.test("deleting the model leaves a working app") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        SavingsBenchmark.train([personal], on: corpus)

        let engine = SuggestionEngine()
        engine.register(personal)
        engine.register(FakeModel(name: "temporary", reply: "irrelevant "))

        // Swap to memory-only, exactly as choosing "No model" does.
        engine.removeAllSources()
        engine.register(personal)

        let context = TypingContext(textBeforeCaret: "please find ",
                                    currentWordPrefix: "",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        s.expect(engine.bestCandidate(for: context) != nil,
                 "still suggests with no model attached")
    }

    s.test("hot-swapping models leaves memory untouched") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        SavingsBenchmark.train([personal], on: corpus)

        let before = try store.totalWordCount()
        let beforeVocab = try store.allVocab().count

        let engine = SuggestionEngine()
        for model in [FakeModel(name: "qwen", reply: "alpha "),
                      FakeModel(name: "gemma", reply: "beta "),
                      FakeModel(name: "custom", reply: "gamma ")] {
            engine.removeAllSources()
            engine.register(personal)
            engine.register(model)
            _ = engine.bestCandidate(for: TypingContext(textBeforeCaret: "thanks ",
                                                        currentWordPrefix: "",
                                                        appBundleID: nil,
                                                        isAuthoritative: true))
        }

        s.expectEqual(try store.totalWordCount(), before, "word counts unchanged by swaps")
        s.expectEqual(try store.allVocab().count, beforeVocab, "vocabulary unchanged by swaps")
    }

    s.test("a model that returns nothing degrades rather than blocks") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        SavingsBenchmark.train([personal], on: corpus)

        let engine = SuggestionEngine()
        engine.register(personal)
        engine.register(FakeModel(name: "dead", reply: ""))

        // Mid-sentence on purpose. After "kaise ho" the corpus always ends the
        // sentence, and the model now knows that — it predicts the break, which is
        // correct and which has no text to insert, so the honest answer there is
        // silence rather than a word.
        let context = TypingContext(textBeforeCaret: "Let me know if that ",
                                    currentWordPrefix: "",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        s.expect(engine.bestCandidate(for: context) != nil, "memory carries it")
    }

    s.report("Only Tab and left arrow complete")

    s.test("no key other than Tab or left arrow ever accepts a suggestion") {
        // Everything else passes through untouched, leaving the text exactly as
        // typed — right arrow explicitly included, so nudging the caret rightwards
        // never takes a suggestion by accident.
        let candidate = Candidate(text: "regards, Anand", probability: 0.8, origin: .snippet)

        let nonAcceptingKeys: [(String, KeyEvent)] = [
            ("Return", KeyEvent(keyCode: Int64(kVK_Return), characters: "\r", modifiers: [])),
            ("Enter", KeyEvent(keyCode: Int64(kVK_ANSI_KeypadEnter), characters: "\r", modifiers: [])),
            ("Space", KeyEvent(keyCode: Int64(kVK_Space), characters: " ", modifiers: [])),
            ("Escape", KeyEvent(keyCode: Int64(kVK_Escape), characters: "", modifiers: [])),
            ("Right arrow", KeyEvent(keyCode: Int64(kVK_RightArrow), characters: "", modifiers: [])),
            ("Up arrow", KeyEvent(keyCode: Int64(kVK_UpArrow), characters: "", modifiers: [])),
            ("Down arrow", KeyEvent(keyCode: Int64(kVK_DownArrow), characters: "", modifiers: [])),
            ("letter", KeyEvent(keyCode: Int64(kVK_ANSI_A), characters: "a", modifiers: []))
        ]

        for (label, key) in nonAcceptingKeys {
            let controller = AcceptanceController()
            controller.present(candidate)
            let outcome = controller.handle(key)
            if case .accept = outcome {
                s.expect(false, "\(label) must not accept — got \(outcome)")
            } else {
                s.expect(true, "\(label) passes through")
            }
        }

        // Both accept keys do.
        for (label, code) in [("Tab", kVK_Tab), ("left arrow", kVK_LeftArrow)] {
            let controller = AcceptanceController()
            controller.present(candidate)
            if case .accept = controller.handle(KeyEvent(keyCode: Int64(code),
                                                         characters: "",
                                                         modifiers: [])) {
                s.expect(true, "\(label) accepts")
            } else {
                s.expect(false, "\(label) must accept")
            }
        }

        // But with nothing pending they still just move the caret / indent.
        for (label, code) in [("Tab", kVK_Tab), ("left arrow", kVK_LeftArrow)] {
            let idle = AcceptanceController()
            s.expectEqual(idle.handle(KeyEvent(keyCode: Int64(code), characters: "", modifiers: [])),
                          .passThrough,
                          "\(label) passes through when nothing is pending")
        }
    }

    s.test("ranking prefers a correction over a short completion") {
        // Corrections carry the retyping they spare you, so they outrank a
        // two-character completion despite being short.
        let ranker = Ranker()
        let correction = Candidate(text: "receive", probability: 0.6,
                                   origin: .correction, replacesPreviousCharacters: 7)
        let completion = Candidate(text: "ing ", probability: 0.8, origin: .prefixTrie)

        s.expectEqual(ranker.best([completion, correction])?.origin, .correction,
                      "correction wins on expected savings")
        s.expectEqual(Ranker.keystrokesSaved(correction), 13, "deletions counted")
    }
}
