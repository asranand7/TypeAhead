import Foundation
import TypeAheadCore

/// The objective function is the heart of the design, so it gets the most tests.
func runRankerTests(_ s: Suite) {
    s.report("Ranker")
    let ranker = Ranker()

    s.test("long phrase at moderate confidence beats short word at high confidence") {
        // The plan's headline ranking claim, as an executable assertion. Stated
        // for a snippet, because that is the tier that actually emits phrases —
        // the n-gram source returns one word at a time.
        let phrase = Candidate(text: "me know if that works",  // 5 words
                               probability: 0.4,
                               origin: .snippet)
        let word = Candidate(text: "the ",                     // 4 chars, 3 saved
                             probability: 0.9,
                             origin: .snippet)

        s.expectEqual(ranker.best([word, phrase])?.text, phrase.text, "phrase wins")
        s.expectClose(Ranker.expectedSavings(phrase), 4.739, "phrase expected savings")
        s.expectClose(Ranker.expectedSavings(word), 3.15, "word expected savings")
    }

    s.test("phrase value is bounded, so length alone cannot win") {
        // The defect this replaced: expected savings were P x raw length, with no
        // cap, so a long enough suggestion outranked everything regardless of how
        // likely it was. In a real store that made the snippet tier the most-shown
        // and least-accepted source by a wide margin.
        //
        // The claim here is not that a long phrase always loses — a 52-character
        // phrase at 20% really is worth more than a 4-character word at 70%. It is
        // that its value no longer scales with its length.
        let rambling = Candidate(
            text: "me know if that works for you and if not just say so",
            probability: 0.2, origin: .snippet)

        let underOldFormula = 0.2 * Double(rambling.text.count - 1)
        s.expect(Ranker.expectedSavings(rambling) < underOldFormula / 3,
                 "long phrase is worth a fraction of its raw length")

        // Weights sum to 1/(1-q), so the whole phrase can never exceed that many
        // single words however far it runs on.
        let ceiling = 0.2 * (1 / (1 - Ranker.continuation(for: .snippet)))
            * Double(rambling.acceptanceUnits.map(\.count).max() ?? 0)
        s.expect(Ranker.expectedSavings(rambling) < ceiling, "value is bounded")
    }

    s.test("chained statistics decay faster than verbatim recall") {
        // Same text, same confidence, different evidence. An n-gram builds a
        // phrase one fresh guess at a time and its error compounds; a snippet is
        // one thing the user has already written.
        let text = "me know if that works"
        let asSnippet = Candidate(text: text, probability: 0.4, origin: .snippet)
        let asNgram = Candidate(text: text, probability: 0.4, origin: .ngram)

        s.expect(Ranker.expectedSavings(asSnippet) > Ranker.expectedSavings(asNgram),
                 "verbatim recall is worth more than a chained guess")
    }

    s.test("a near-certain single character is shown; an uncertain one is not") {
        // Reversed deliberately. Charging a full keystroke for the Tab made a
        // one-character completion worth exactly zero *by definition*, so the
        // most confident prediction the system can make — "I will conside" to
        // "consider" at p=0.95 — could never reach the screen however sure it
        // was. Tab is one fixed key already under the finger, not a letter that
        // has to be found, so it costs half.
        let certain = Candidate(text: "r", probability: 0.95, origin: .lexicon)
        s.expectEqual(ranker.best([certain])?.text, "r", "a near-certain letter is worth offering")

        // The gate still does its job everywhere below that.
        let unsure = Candidate(text: "s", probability: 0.4, origin: .ngram)
        s.expectNil(ranker.best([unsure]), "an uncertain single character is not")
    }

    s.test("nothing to insert is never shown, however certain") {
        let empty = Candidate(text: "", probability: 1.0, origin: .lexicon)
        s.expectNil(ranker.best([empty]), "an empty candidate cannot clear the gate")
    }

    s.test("the gate rejects low expected savings") {
        let weak = Candidate(text: "ing ", probability: 0.1, origin: .model)  // 0.3 expected
        s.expectNil(ranker.best([weak]), "weak candidate gated out")

        let permissive = Ranker(minimumExpectedSavings: 0.2)
        s.expectEqual(permissive.best([weak])?.text, weak.text, "gate is configurable")
    }

    s.test("ties break toward the higher probability") {
        // Equal expected value: prefer the one more likely to be right, so the
        // user's trust in the ghost text stays calibrated.
        let confident = Candidate(text: "abc", probability: 0.9, origin: .snippet)    // 2.25
        let speculative = Candidate(text: "abcde", probability: 0.5, origin: .model) // 2.25

        s.expectClose(Ranker.expectedSavings(confident),
                      Ranker.expectedSavings(speculative),
                      "the two are worth the same")
        s.expectEqual(ranker.best([speculative, confident])?.origin, .snippet,
                      "confident candidate wins the tie")
    }

    s.test("ranking is deterministic and correctly ordered") {
        let candidates = [
            Candidate(text: "regards, Anand", probability: 0.5, origin: .snippet),
            Candidate(text: "ho ", probability: 0.9, origin: .ngram),
            Candidate(text: "bility ", probability: 0.7, origin: .prefixTrie)
        ]
        let first = ranker.ranked(candidates).map(\.text)
        let second = ranker.ranked(candidates).map(\.text)

        s.expectEqual(first, second, "stable across runs")
        s.expectEqual(first, ["regards, Anand", "bility ", "ho "], "ordered by expected savings")
    }
}
