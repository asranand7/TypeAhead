import Foundation
import TypeAheadCore

/// Backoff, which for a long time did not back off.
func runBackoffTests(_ s: Suite) {
    s.report("N-gram backoff")

    s.test("a mid-sentence bigram is visible to the bigram tier") {
        // The defect: `recordNgram` wrote one row per word, at the trigram
        // context. The bigram tier queried a context that was only ever written
        // right after a caret reset, so mid-sentence evidence — the overwhelming
        // majority of it — was invisible to every tier but the trigram.
        let (store, _) = try makeTemporaryStore()
        let a = try store.recordWord("please")
        let b = try store.recordWord("find")
        let c = try store.recordWord("attached")

        // "please find attached", mid-sentence: a full trigram context.
        try store.recordNgram(prev2: a, prev1: b, next: c, app: "")

        let bigram = try store.continuations(prev2: Store.anyWord, prev1: b, app: "")
        s.expect(bigram.contains { $0.word == "attached" },
                 "'attached' follows 'find' whatever preceded it")

        let unigram = try store.continuations(prev2: Store.anyWord,
                                              prev1: Store.anyWord, app: "")
        s.expect(unigram.contains { $0.word == "attached" },
                 "'attached' is visible with no context at all")
    }

    s.test("a word with no history is counted once, not three times") {
        // The three context depths coincide for the very first word of a reset,
        // and writing that row once per depth would treble its weight.
        let (store, _) = try makeTemporaryStore()
        let id = try store.recordWord("hello")
        try store.recordNgram(prev2: 0, prev1: 0, next: id, app: "")

        let rows = try store.continuations(prev2: 0, prev1: 0, app: "")
        s.expectEqual(rows.first { $0.word == "hello" }?.count, 1,
                      "one occurrence, one count")
    }

    s.test("the marginal sentinel is not confusable with 'no preceding word'") {
        // Overloading 0 for both questions is what made the first attempt at
        // this wrong: a sentence-start observation and a marginal shared a key.
        let (store, _) = try makeTemporaryStore()
        let first = try store.recordWord("hi")
        let other = try store.recordWord("there")
        try store.recordNgram(prev2: 0, prev1: 0, next: first, app: "")
        try store.recordNgram(prev2: first, prev1: other, next: first, app: "")

        let sentenceStarts = try store.continuations(prev2: 0, prev1: 0, app: "")
        let marginal = try store.continuations(prev2: Store.anyWord,
                                               prev1: Store.anyWord, app: "")
        let startCount = sentenceStarts.first { $0.word == "hi" }?.count ?? 0
        let marginalCount = marginal.first { $0.word == "hi" }?.count ?? 0
        s.expectEqual(startCount, 1, "one sentence-start observation")
        s.expectEqual(marginalCount, 2, "two occurrences overall")
    }

    s.test("the personal model predicts from a bigram it only saw mid-sentence") {
        // End to end: the user's evidence reaching a prediction, which before
        // the marginals it could not.
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)
        for _ in 0..<3 {
            model.observe(.wordCommitted(word: "please", boundary: .space, appBundleID: nil))
            model.observe(.wordCommitted(word: "find", boundary: .space, appBundleID: nil))
            model.observe(.wordCommitted(word: "attached", boundary: .space, appBundleID: nil))
            model.observe(.wordCommitted(word: "the", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }

        // A context the trigram tier has never seen: "just find".
        let context = TypingContext(textBeforeCaret: "just find ",
                                    currentWordPrefix: "",
                                    appBundleID: nil,
                                    isAuthoritative: true)
        let suggestions = model.suggest(context)
        s.expect(suggestions.contains { $0.text.trimmingCharacters(in: .whitespaces) == "attached" },
                 "backs off to the bigram and still predicts 'attached'")
    }
}
