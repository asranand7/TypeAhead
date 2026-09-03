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
