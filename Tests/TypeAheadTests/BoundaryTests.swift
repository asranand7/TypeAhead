import Foundation
import TypeAheadCore

func runBoundaryTests(_ s: Suite) {
    s.report("Sentence and paragraph boundaries")

    s.test("separators are classified, not discarded") {
        s.expectEqual(TextBoundary(separator: " "), .space, "space")
        s.expectEqual(TextBoundary(separator: ","), .clause, "comma")
        s.expectEqual(TextBoundary(separator: "."), .sentence, "full stop")
        s.expectEqual(TextBoundary(separator: "\n"), .paragraph, "newline")
        // The Return key delivers a carriage return, not a newline. Handling only
        // "\n" left every shadow-buffer app blind to paragraph breaks.
        s.expectEqual(TextBoundary(separator: "\r"), .paragraph, "carriage return")
        s.expect(TextBoundary.sentence.endsSentence, "a full stop ends a sentence")
        s.expect(!TextBoundary.clause.endsSentence, "a comma does not")
    }

    s.test("a run of separators collapses to its strongest member") {
        s.expectEqual(TextBoundary.strongest(.sentence, .paragraph), .paragraph,
                      "newline after a full stop is one paragraph break")
        s.expectEqual(TextBoundary.strongest(.clause, .space), .clause, "comma beats space")
    }

    s.test("the model's token sequence carries the breaks") {
        s.expectEqual(PersonalModel.tokens(of: "Sounds good. Thanks"),
                      ["sounds", "good", PersonalModel.BoundaryToken.sentence, "thanks"],
                      "full stop becomes a sentence token")
        s.expectEqual(PersonalModel.tokens(of: "Hi John,\n\nI"),
                      ["hi", "john", PersonalModel.BoundaryToken.paragraph, "i"],
                      "comma then blank line becomes one paragraph token")
        // The case that used to make two different contexts identical.
        s.expect(PersonalModel.tokens(of: "Sounds good. Thanks")
                    != PersonalModel.tokens(of: "Sounds good Thanks"),
                 "a full stop changes the context")
    }

    s.test("learning and prediction agree on the sequence") {
        // The two have to produce the same tokens or every trigram recorded at
        // learning time is looked up under a key that was never written.
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)
        let text = "Hi John,\n\nThanks for the update. Please find attached the report.\n"
        SavingsBenchmark.train([model], on: text)

        let reconstructed = PersonalModel.tokens(of: text)
        s.expect(reconstructed.contains(PersonalModel.BoundaryToken.paragraph),
                 "paragraph token reconstructed from the finished text")
        s.expect(reconstructed.contains(PersonalModel.BoundaryToken.sentence),
                 "sentence token reconstructed from the finished text")

        // And the boundary tokens are machinery, not vocabulary.
        let vocab = try store.allVocab().map(\.word)
        s.expect(!vocab.contains(PersonalModel.BoundaryToken.sentence),
                 "sequence markers stay out of the user's word list")
        s.expect(vocab.contains("thanks"), "real words are still there")
    }

    s.report("Separators and casing on insertion")

    s.test("a suggestion after bare punctuation carries its own space") {
        s.expectEqual(PersonalModel.leadingSeparator(for: "Hi John,"), " ",
                      "bare comma needs a space")
        s.expectEqual(PersonalModel.leadingSeparator(for: "that."), " ",
                      "bare full stop needs a space")
        s.expectEqual(PersonalModel.leadingSeparator(for: "Hi John, "), "",
                      "a space is already there")
        s.expectEqual(PersonalModel.leadingSeparator(for: "the file.\n"), "",
                      "a newline is whitespace too")
        s.expectEqual(PersonalModel.leadingSeparator(for: "attach"), "",
                      "mid-word needs nothing")
    }

    s.test("a suggestion starting a sentence is capitalised") {
        s.expect(PersonalModel.startsSentence(""), "empty field starts a sentence")
        s.expect(PersonalModel.startsSentence("Thanks for that. "), "after a full stop")
        s.expect(PersonalModel.startsSentence("Hi John,\n\n"), "after a paragraph break")
        s.expect(!PersonalModel.startsSentence("Please find "), "mid-sentence")
        s.expectEqual(PersonalModel.capitalized("please"), "Please", "first letter only")
        s.expectEqual(PersonalModel.capitalized("iPhone"), "IPhone", "no rewriting past the first")
    }

    s.test("the glued-suggestion bug stays fixed") {
        // "Hi John," + "thanks " used to produce "Hi John,thanks ".
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)
        for _ in 0..<4 {
            SavingsBenchmark.train([model], on: "Hi John, thanks for that. Please send the file.\n")
        }
        let engine = SuggestionEngine()
        engine.register(model)

        for before in ["Hi John,", "that.", "Hi John, ", "that. "] {
            let context = TypingContext(textBeforeCaret: before,
                                        currentWordPrefix: "",
                                        appBundleID: nil,
                                        isAuthoritative: true)
            guard let candidate = engine.bestCandidate(for: context) else { continue }
            let result = before + candidate.text
            s.expect(!result.contains(",t") && !result.contains(".t") && !result.contains(".P"),
                     "no text welded to punctuation — got \(result.debugDescription)")
            s.expect(!result.contains("  "), "no doubled space — got \(result.debugDescription)")
        }
    }

    s.report("Snippets keep their punctuation")

    s.test("phrases are not mined across a sentence or paragraph break") {
        let (store, _) = try makeTemporaryStore()
        let miner = SnippetMiner(store: store)
        for _ in 0..<3 {
            SavingsBenchmark.train(
                [miner], on: "Hi John,\n\nThanks for the update. Please find attached.\n")
        }
        let phrases = try store.allSnippets().map(\.text)
        s.expect(!phrases.contains { $0.contains("update Please") },
                 "no phrase spans the full stop — got \(phrases)")
        s.expect(!phrases.contains { $0.contains("John Thanks") },
                 "no phrase spans the paragraph break — got \(phrases)")
        s.expect(phrases.contains { $0.hasPrefix("Thanks for the") },
                 "real within-sentence phrases survive — got \(phrases)")
    }

    s.test("a comma no longer switches the snippet tier off") {
        // "Thanks, " was matched literally against phrases stored as "Thanks Anand"
        // and never hit, so typing a comma silently disabled the best tier.
        s.expectEqual(SnippetSource.matchableTail(of: "Thanks, "), "Thanks, ",
                      "comma survives into the tail")
        s.expectEqual(SnippetSource.matchableTail(of: "Thanks,"), "Thanks, ",
                      "and is canonicalised when the space has not been typed yet")
        s.expectEqual(SnippetSource.matchableTail(of: "ok. Where are you "), "Where are you ",
                      "a full stop still starts a fresh tail")
        s.expectEqual(SnippetSource.matchableTail(of: "Thanks\rBest "), "Best ",
                      "a carriage return does too")
    }

    s.test("a mined phrase round-trips through matching") {
        let (store, _) = try makeTemporaryStore()
        let miner = SnippetMiner(store: store)
        for _ in 0..<3 {
            SavingsBenchmark.train([miner], on: "Thanks, Anand here again.\n")
        }
        let engine = SuggestionEngine()
        engine.register(SnippetSource(store: store))
        let context = TypingContext(textBeforeCaret: "Thanks, ",
                                    currentWordPrefix: "",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        let offered = engine.candidates(for: context).map(\.text)
        s.expect(!offered.isEmpty,
                 "a phrase typed with a comma is offered after a comma — got \(offered)")
    }
}

func runMigrationTests(_ s: Suite) {
    s.report("Schema 3 — statistics reset")

    s.test("clears punctuation-blind statistics and keeps everything else") {
        let path = NSTemporaryDirectory() + "migrate-\(UUID().uuidString).sqlite"

        // A store as schema 2 left it: statistics and phrases recorded without
        // separators, alongside vocabulary and corrections that are still valid.
        do {
            let old = try Store(path: path)
            old.database.userVersion = 2
            let a = try old.recordWord("chaudhary")
            let b = try old.recordWord("anand")
            try old.recordNgram(prev2: a, prev1: b, next: a, app: "")
            try old.recordSnippet("Thanks Anand here", source: "auto")
            try old.recordSnippet("My own phrase", source: "manual")
            try old.recordCorrection(wrong: "recieve", right: "receive")
            try old.recordShown(origin: .ngram, app: "")

            s.expect(try old.allVocab().count >= 2, "vocabulary written")
        }

        // Reopening runs the migration.
        let migrated = try Store(path: path)
        s.expectEqual(migrated.database.userVersion, Store.schemaVersion, "version bumped")

        let vocab = try migrated.allVocab().map(\.word)
        s.expect(vocab.contains("chaudhary"), "vocabulary survives — months to relearn")
        s.expectEqual(try migrated.allCorrections().count, 1, "corrections survive")

        let phrases = try migrated.allSnippets()
        s.expect(!phrases.contains { $0.text == "Thanks Anand here" },
                 "auto-mined phrases without punctuation are cleared")
        s.expect(phrases.contains { $0.text == "My own phrase" },
                 "phrases the user added by hand are kept")

        let counts = try migrated.acceptanceCounts()
        s.expect(counts.isEmpty, "feedback measured against the old ranking is cleared")

        // And the statistics really are gone, not merely unreachable.
        let rows = try migrated.database.query("SELECT COUNT(*) AS n FROM ngram")
        s.expectEqual(Int(rows.first?.int("n") ?? -1), 0, "n-gram table emptied")
    }

    s.test("migration is idempotent") {
        let path = NSTemporaryDirectory() + "migrate2-\(UUID().uuidString).sqlite"
        do {
            let fresh = try Store(path: path)
            let id = try fresh.recordWord("hello")
            try fresh.recordNgram(prev2: 0, prev1: 0, next: id, app: "")
        }
        // Already at the current version: reopening must not wipe live learning.
        let reopened = try Store(path: path)
        let rows = try reopened.database.query("SELECT COUNT(*) AS n FROM ngram")
        s.expect(Int(rows.first?.int("n") ?? 0) > 0,
                 "a store already migrated keeps its statistics")
    }
}

func runForgetTests(_ s: Suite) {
    s.report("Forgetting a word")

    s.test("forgetting removes the statistics that referred to it") {
        let (store, _) = try makeTemporaryStore()
        let alpha = try store.recordWord("alpha")
        let beta = try store.recordWord("beta")
        let gamma = try store.recordWord("gamma")
        try store.recordNgram(prev2: alpha, prev1: beta, next: gamma, app: "")
        try store.recordNgram(prev2: beta, prev1: gamma, next: alpha, app: "")

        try store.forgetWord("gamma")

        let rows = try store.database.query(
            "SELECT COUNT(*) AS n FROM ngram WHERE next_id = ? OR prev1 = ? OR prev2 = ?",
            [.integer(gamma), .integer(gamma), .integer(gamma)])
        s.expectEqual(Int(rows.first?.int("n") ?? -1), 0,
                      "no n-gram still refers to the forgotten word")
        s.expect(!(try store.allVocab().map(\.word).contains("gamma")), "word is gone")
        s.expect(try store.allVocab().map(\.word).contains("alpha"), "others untouched")
    }

    s.test("a forgotten word cannot come back wearing a new word's name") {
        // vocab.id is a rowid alias. Deleting the highest-numbered row frees that
        // id, and the next word learned is handed it — so every n-gram that
        // pointed at the deleted word silently starts pointing at the new one.
        // Deleting the word you just mistyped is precisely what triggers it.
        let (store, _) = try makeTemporaryStore()
        let a = try store.recordWord("alpha")
        let b = try store.recordWord("beta")
        let doomed = try store.recordWord("secret")
        try store.recordNgram(prev2: a, prev1: b, next: doomed, app: "")

        try store.forgetWord("secret")
        let reused = try store.recordWord("innocent")

        if reused == doomed {
            // The id really was recycled — so the guarantee has to come from the
            // statistics having been deleted, not from the id being unique.
            let rows = try store.continuations(prev2: a, prev1: b, app: "")
            s.expect(!rows.contains { $0.word == "innocent" },
                     "the new word did not inherit the forgotten one's predictions")
        }
        s.expect(true, "rowid reuse checked")
    }

    s.test("forgetting takes phrases containing the word, but not lookalikes") {
        let (store, _) = try makeTemporaryStore()
        _ = try store.recordWord("anand")
        try store.recordSnippet("Thanks, Anand", source: "auto")
        try store.recordSnippet("Please find attached", source: "auto")
        // Substring, not a word: forgetting "an" must not take this with it.
        _ = try store.recordWord("an")
        try store.recordSnippet("many happy returns", source: "auto")

        try store.forgetWord("anand")
        let remaining = try store.allSnippets().map(\.text)
        s.expect(!remaining.contains("Thanks, Anand"), "phrase containing the word is gone")
        s.expect(remaining.contains("Please find attached"), "unrelated phrase kept")

        try store.forgetWord("an")
        let after = try store.allSnippets().map(\.text)
        s.expect(after.contains("many happy returns"),
                 "a phrase merely containing the letters is kept")
    }
}

func runPruneTests(_ s: Suite) {
    s.report("Pruning unrepeated phrases")

    s.test("a phrase seen once and left alone is eventually discarded") {
        let (store, _) = try makeTemporaryStore()
        try store.recordSnippet("typed once and never again", source: "auto")
        try store.recordSnippet("let me know if that works", source: "auto")
        try store.recordSnippet("let me know if that works", source: "auto")  // repeated
        try store.recordSnippet("my own phrase", source: "manual")

        let later = Date().addingTimeInterval(Store.unrepeatedSnippetLifetime + 60)
        let removed = try store.pruneUnrepeatedSnippets(now: later)

        let remaining = try store.allSnippets().map(\.text)
        s.expectEqual(removed, 1, "exactly the one-sighting phrase went")
        s.expect(!remaining.contains("typed once and never again"), "candidate discarded")
        s.expect(remaining.contains("let me know if that works"),
                 "a phrase that repeated is a habit, kept whatever its age")
        s.expect(remaining.contains("my own phrase"),
                 "a phrase added by hand is not the miner's to discard")
    }

    s.test("a fresh candidate survives the sweep") {
        // The whole point of recording every length is fast discovery. A sweep
        // that took this afternoon's candidates would defeat it.
        let (store, _) = try makeTemporaryStore()
        try store.recordSnippet("mined a moment ago", source: "auto")
        s.expectEqual(try store.pruneUnrepeatedSnippets(), 0, "nothing removed")
        s.expect(try store.allSnippets().map(\.text).contains("mined a moment ago"), "kept")
    }

    s.test("the ceiling bounds a heavy writing day") {
        let (store, _) = try makeTemporaryStore()
        for index in 0..<40 { try store.recordSnippet("candidate number \(index)", source: "auto") }
        try store.recordSnippet("kept because it repeated", source: "auto")
        try store.recordSnippet("kept because it repeated", source: "auto")

        let removed = try store.pruneUnrepeatedSnippets(keepingAtMost: 10)
        s.expectEqual(removed, 30, "trimmed to the ceiling")

        let remaining = try store.allSnippets()
        s.expectEqual(remaining.filter { $0.count == 1 }.count, 10, "ceiling honoured")
        s.expect(remaining.contains { $0.text == "kept because it repeated" },
                 "repeated phrases are never counted against the ceiling")
    }
}
