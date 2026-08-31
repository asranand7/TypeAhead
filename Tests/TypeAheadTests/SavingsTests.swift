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

    // A corpus in the four registers the app has to handle, with the repetition a
    // real person's writing actually contains.
    let corpus = """
        thanks anand let me know if that works. \
        please find attached the report for review. \
        kaise ho bhai sab theek hai na. \
        thanks anand let me know if that works. \
        please find attached the deck for review. \
        kaise ho bhai sab theek hai na. \
        thanks anand let me know if that works. \
        please find attached the notes for review. \
        kaise ho bhai sab theek hai na.
        """

    s.test("replaying your own writing saves a meaningful share of keystrokes") {
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        let miner = SnippetMiner(store: store)
        let snippets = SnippetSource(store: store)

        SavingsBenchmark.train([personal, miner], on: corpus)

        let engine = SuggestionEngine()
        engine.register(snippets)
        engine.register(personal)

        let result = SavingsBenchmark(engine: engine).replay(corpus)
        let byOrigin = result.acceptedByOrigin
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \($0.value)" }
            .joined(separator: ", ")
        s.report(String(format: "    → %.1f%% saved (%d of %d keystrokes; %@)",
                        result.percentSaved,
                        result.charactersTyped - result.keystrokesUsed,
                        result.charactersTyped,
                        byOrigin))
        s.expect(result.percentSaved > 20,
                 "saved \(String(format: "%.1f", result.percentSaved))% — expected more than 20%")
        s.expect(result.keystrokesUsed < result.charactersTyped,
                 "fewer keystrokes than characters")
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

        let context = TypingContext(textBeforeCaret: "kaise ho ",
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
