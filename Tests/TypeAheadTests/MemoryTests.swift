import Foundation
import TypeAheadCore

/// A throwaway store on disk. Real SQLite rather than a fake, because the merge
/// logic *is* SQL and a fake would test the wrong thing.
func makeTemporaryStore() throws -> (store: Store, path: String) {
    let path = NSTemporaryDirectory() + "typeahead-test-\(UUID().uuidString).sqlite"
    return (try Store(path: path), path)
}

func runMemoryTests(_ s: Suite) {
    s.report("Memory & learning")

    s.test("the personal model learns a word and completes it") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        // A name is in no dictionary, so it must clear the higher bar for
        // unrecognised words before it is offered — see WordHygiene.
        for _ in 0..<WordHygiene.unknownWordThreshold {
            model.observe(.wordCommitted(word: "chaudhary", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }

        let context = TypingContext(textBeforeCaret: "chaud",
                                    currentWordPrefix: "chaud",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        let candidates = model.suggest(context)
        s.expect(candidates.contains { $0.text == "hary" },
                 "completes a learned name — got \(candidates.map(\.text))")
    }

    s.test("a word seen once is not offered") {
        // One sighting is as likely to be a typo as a word.
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)
        model.observe(.wordCommitted(word: "provisional", boundary: .space, appBundleID: nil))

        let context = TypingContext(textBeforeCaret: "provis",
                                    currentWordPrefix: "provis",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        s.expect(model.suggest(context).isEmpty, "single sighting withheld")
    }

    s.test("the personal model predicts the next word from context") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        for _ in 0..<3 {
            model.observe(.caretMoved)
            model.observe(.wordCommitted(word: "kaise", boundary: .space, appBundleID: nil))
            model.observe(.wordCommitted(word: "ho", boundary: .space, appBundleID: nil))
            model.observe(.wordCommitted(word: "bhai", boundary: .space, appBundleID: nil))
        }

        let context = TypingContext(textBeforeCaret: "kaise ho ",
                                    currentWordPrefix: "",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        let candidates = model.suggest(context)
        s.expect(candidates.contains { $0.text.trimmingCharacters(in: .whitespaces) == "bhai" },
                 "predicts the learned continuation — got \(candidates.map(\.text))")
    }

    s.test("Devanagari is learned exactly like Latin") {
        // No special-casing anywhere in the pipeline — the point of the design.
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)
        for _ in 0..<2 {
            model.observe(.wordCommitted(word: "नमस्ते", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }
        s.expectEqual(try store.wordCount("नमस्ते"), 2, "Devanagari word counted")
    }

    s.test("per-app context is kept separate") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        for _ in 0..<3 {
            model.observe(.caretMoved)
            model.observe(.wordCommitted(word: "hey", boundary: .space, appBundleID: "com.slack"))
            model.observe(.wordCommitted(word: "team", boundary: .space, appBundleID: "com.slack"))
        }
        for _ in 0..<3 {
            model.observe(.caretMoved)
            model.observe(.wordCommitted(word: "hey", boundary: .space, appBundleID: "com.mail"))
            model.observe(.wordCommitted(word: "there", boundary: .space, appBundleID: "com.mail"))
        }

        let slack = model.suggest(TypingContext(textBeforeCaret: "hey ",
                                                currentWordPrefix: "",
                                                appBundleID: "com.slack",
                                                isAuthoritative: true))
        let mail = model.suggest(TypingContext(textBeforeCaret: "hey ",
                                               currentWordPrefix: "",
                                               appBundleID: "com.mail",
                                               isAuthoritative: true))

        s.expectEqual(slack.first?.text.trimmingCharacters(in: .whitespaces), "team",
                      "Slack continuation")
        s.expectEqual(mail.first?.text.trimmingCharacters(in: .whitespaces), "there",
                      "Mail continuation")
    }

    s.test("snippets are promoted only after enough repeats") {
        let (store, _) = try makeTemporaryStore()
        let miner = SnippetMiner(store: store)
        let source = SnippetSource(store: store)

        let phrase = ["let", "me", "know", "if", "that", "works"]
        for _ in 0..<(SnippetMiner.promotionThreshold - 1) {
            miner.observe(.caretMoved)
            for word in phrase { miner.observe(.wordCommitted(word: word, boundary: .space, appBundleID: nil)) }
        }

        let early = source.suggest(TypingContext(textBeforeCaret: "let me know",
                                                 currentWordPrefix: "know",
                                                 appBundleID: nil,
                                                 isAuthoritative: true))
        s.expect(early.isEmpty, "not promoted below the threshold")

        miner.observe(.caretMoved)
        for word in phrase { miner.observe(.wordCommitted(word: word, boundary: .space, appBundleID: nil)) }

        let promoted = try miner.promoted()
        s.expect(promoted.contains { $0.text == "let me know if that works" },
                 "promoted at the threshold — got \(promoted.map(\.text))")
    }

    s.test("a caret jump does not splice unrelated words into a phrase") {
        // Words either side of a click were never adjacent; mining across the gap
        // would invent phrases the user never typed.
        let (store, _) = try makeTemporaryStore()
        let miner = SnippetMiner(store: store)

        for word in ["alpha", "beta"] { miner.observe(.wordCommitted(word: word, boundary: .space, appBundleID: nil)) }
        miner.observe(.caretMoved)
        for word in ["gamma", "delta"] { miner.observe(.wordCommitted(word: word, boundary: .space, appBundleID: nil)) }

        let all = try store.allSnippets()
        s.expect(!all.contains { $0.text.contains("beta gamma") },
                 "no phrase spans the caret jump")
    }

    s.test("identity is detected but never stored confirmed without asking") {
        let (store, _) = try makeTemporaryStore()
        let detector = IdentityDetector(store: store)
        var asked: [String] = []
        detector.onCandidate = { _, value in asked.append(value) }

        for _ in 0..<IdentityDetector.promptThreshold {
            detector.observe(.caretMoved)
            detector.observe(.typed("testuser@example.com "))
        }

        s.expect(asked.contains("testuser@example.com"), "asked about the repeated address")
        s.expect(try store.identityFacts(confirmedOnly: true).isEmpty,
                 "nothing confirmed without an answer")
        s.expect(!(try store.identityFacts(confirmedOnly: false).isEmpty),
                 "held as an unconfirmed candidate")
    }

    s.test("a confirmed identity fact completes from a short prefix") {
        let (store, _) = try makeTemporaryStore()
        try store.setIdentity("email", "testuser@example.com")
        let source = IdentitySource(store: store)

        let candidates = source.suggest(TypingContext(textBeforeCaret: "tes",
                                                      currentWordPrefix: "tes",
                                                      appBundleID: nil,
                                                      isAuthoritative: true))
        s.expectEqual(candidates.first?.text, "tuser@example.com", "completes the address")
        s.expect(Ranker.keystrokesSaved(candidates[0]) > 14,
                 "saves a lot — this is the highest-value tier")
    }

    s.test("corrections are learned from type, delete, retype") {
        let (store, _) = try makeTemporaryStore()
        let corrector = Corrector(store: store)

        for _ in 0..<Corrector.minimumEvidence {
            corrector.observe(.caretMoved)
            corrector.observe(.wordCommitted(word: "recieve", boundary: .space, appBundleID: nil))
            for _ in 0..<("recieve".count + 1) { corrector.observe(.backspaced) }
            corrector.observe(.typed("r"))
            corrector.observe(.wordCommitted(word: "receive", boundary: .space, appBundleID: nil))
        }

        let pair = try store.correction(for: "recieve")
        s.expectEqual(pair?.right, "receive", "pair recorded")
        s.expectEqual(pair?.count, Corrector.minimumEvidence, "counted each time")
    }

    s.test("a deliberate reword is not mistaken for a typo") {
        // Rewriting "hello" as "hi" is editing. Recording it would make the app
        // "fix" a perfectly good word later.
        s.expect(!Corrector.isPlausibleTypoFix(from: "hello", to: "hi"), "reword rejected")
        s.expect(Corrector.isPlausibleTypoFix(from: "recieve", to: "receive"), "typo accepted")
        s.expect(!Corrector.isPlausibleTypoFix(from: "cat", to: "cat"), "identical rejected")
    }

    s.test("a correction replaces what was typed rather than appending") {
        let (store, _) = try makeTemporaryStore()
        try store.recordCorrection(wrong: "teh", right: "the")
        try store.recordCorrection(wrong: "teh", right: "the")
        let corrector = Corrector(store: store)

        let candidates = corrector.suggest(TypingContext(textBeforeCaret: "teh",
                                                         currentWordPrefix: "teh",
                                                         appBundleID: nil,
                                                         isAuthoritative: true))
        s.expectEqual(candidates.first?.text, "the", "offers the fix")
        s.expectEqual(candidates.first?.replacesPreviousCharacters, 3, "replaces the typo")
    }

    s.test("words you use often are protected from correction") {
        // The feature that stops the app fighting you over names, jargon and
        // Hinglish the way system autocorrect does.
        let (store, _) = try makeTemporaryStore()
        try store.recordCorrection(wrong: "nahi", right: "nash")
        try store.recordCorrection(wrong: "nahi", right: "nash")
        for _ in 0..<Corrector.protectionThreshold { try store.recordWord("nahi") }

        let corrector = Corrector(store: store)
        let candidates = corrector.suggest(TypingContext(textBeforeCaret: "nahi",
                                                         currentWordPrefix: "nahi",
                                                         appBundleID: nil,
                                                         isAuthoritative: true))
        s.expect(candidates.isEmpty, "your own word is never 'corrected'")
    }

    s.test("correction casing follows what you typed") {
        s.expectEqual(Corrector.matchCasing(of: "Recieve", to: "receive"), "Receive", "leading capital")
        s.expectEqual(Corrector.matchCasing(of: "RECIEVE", to: "receive"), "RECEIVE", "all caps")
        s.expectEqual(Corrector.matchCasing(of: "recieve", to: "receive"), "receive", "lower case")
    }
}
