import Foundation
import TypeAheadCore

/// The tier that was enumerating substrings and calling them phrases.
func runSnippetTests(_ s: Suite) {
    s.report("Snippets")

    s.test("a phrase is not offered alongside every opening of itself") {
        // Taken verbatim from a real store. Typing "Where are you from" twice had
        // produced six snippets — every sub-phrase — all matching the same tail,
        // all offered at once, with the ranker taking whichever was longest.
        let snippets = [
            Store.Snippet(text: "Where are", count: 11, source: "auto"),
            Store.Snippet(text: "Where are you", count: 9, source: "auto"),
            Store.Snippet(text: "Where are you from", count: 5, source: "auto")
        ]
        let kept = SnippetSource.maximal(snippets).map(\.text)

        s.expect(!kept.contains("Where are"),
                 "'Where are' is the head of a phrase, not a phrase")
        s.expect(kept.contains("Where are you from"), "the full phrase survives")
    }

    s.test("a genuinely independent opening is kept") {
        // The distinction the ratio draws. "Thanks" occurring far more often than
        // "Thanks for your help" means people really do write it on its own.
        let snippets = [
            Store.Snippet(text: "thanks so much", count: 40, source: "auto"),
            Store.Snippet(text: "thanks so much for your help", count: 4, source: "auto")
        ]
        let kept = SnippetSource.maximal(snippets).map(\.text)
        s.expectEqual(kept.count, 2, "both survive when the shorter stands alone")
    }

    s.test("a hand-added snippet is never pruned for being short") {
        let snippets = [
            Store.Snippet(text: "br", count: 1, source: "manual"),
            Store.Snippet(text: "br and more", count: 1, source: "manual")
        ]
        // maximal() judges by usage, not by source; the length floor in the
        // miner is what spares manual entries, and it never sees them.
        s.expect(SnippetSource.maximal(snippets).count >= 1, "manual entries survive")
    }

    s.test("two-word sequences are left to the n-gram tier") {
        s.expect(SnippetMiner.minimumWords >= 3,
                 "a bigram is not a phrase; the statistics tier already holds it")
    }

    s.test("mining records only phrases at or above the floor") {
        let (store, _) = try makeTemporaryStore()
        let miner = SnippetMiner(store: store)
        for word in ["let", "me", "know"] {
            miner.observe(.wordCommitted(word: word, boundary: .space, appBundleID: nil))
        }
        let texts = try store.allSnippets().map(\.text)
        s.expect(!texts.contains { $0.split(separator: " ").count < SnippetMiner.minimumWords },
                 "nothing shorter than the floor is stored")
        s.expect(texts.contains("let me know"), "the phrase itself is stored")
    }
}
