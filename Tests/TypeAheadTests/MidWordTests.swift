import Foundation
import TypeAheadCore

/// Completing a word you are part-way through, and not wrecking one you are not.
func runMidWordTests(_ s: Suite) {
    s.report("Mid-word completion")

    func context(_ before: String, _ prefix: String, after: String = "") -> TypingContext {
        TypingContext(textBeforeCaret: before, currentWordPrefix: prefix,
                      appBundleID: nil, isAuthoritative: true, textAfterCaret: after)
    }

    s.test("the word suffix is read from the text after the caret") {
        s.expectEqual(context("I am recei", "recei", after: "ving the file").currentWordSuffix,
                      "ving", "the tail of the word the caret sits inside")
        s.expectEqual(context("I am recei", "recei", after: " the file").currentWordSuffix,
                      "", "empty at a word boundary")
        s.expectEqual(context("I am recei", "recei").currentWordSuffix,
                      "", "empty when the source cannot see ahead")
    }

    s.test("a completion is not inserted into the middle of a finished word") {
        // The corruption this exists to prevent: the caret inside "recei|ving",
        // every source completing the prefix, and Tab producing "receivedving".
        let ctx = context("I am recei", "recei", after: "ving")
        let ved = Candidate(text: "ved", probability: 0.9, origin: .lexicon)
        s.expectNil(SuggestionEngine.reconcile(ved, with: ctx),
                    "'ved' would corrupt 'receiving'")
    }

    s.test("a completion that spans the tail is trimmed to the difference") {
        // The useful case. "recei|ng" wanting "receiving": the candidate for the
        // whole word is "ving", of which "ng" is already there, so only "vi" is
        // missing. Completing *through* the tail rather than refusing to.
        let ctx = context("I am recei", "recei", after: "ng")
        let ving = Candidate(text: "ving", probability: 0.8, origin: .lexicon)
        let reconciled = SuggestionEngine.reconcile(ving, with: ctx)
        s.expectEqual(reconciled?.text, "vi", "offers only what is missing")
        s.expectEqual(reconciled?.probability, 0.8, "confidence is unchanged")
    }

    s.test("nothing is offered when the word is already complete") {
        let ctx = context("I am recei", "recei", after: "ving")
        let ving = Candidate(text: "ving", probability: 0.9, origin: .lexicon)
        s.expectNil(SuggestionEngine.reconcile(ving, with: ctx),
                    "the word is already what the candidate would make it")
    }

    s.test("a correction is never applied with the caret inside a word") {
        // A correction deletes backwards from the caret; the tail would be left
        // stranded against the replacement.
        let ctx = context("I am recieve", "recieve", after: "d")
        let fix = Candidate(text: "receive", probability: 0.9,
                            origin: .correction, replacesPreviousCharacters: 7)
        s.expectNil(SuggestionEngine.reconcile(fix, with: ctx), "corrections wait for a boundary")
    }

    s.test("a two-letter prefix completes when the grammar pins the form down") {
        // "do" alone is a coin flip between do, does, don't, doing, download and
        // dollar. After "I am" it is not, and that is the whole difference.
        let lexicon = SystemLexicon()
        let constrained = lexicon.suggest(context("I am do", "do"))
        s.expect(constrained.contains { $0.text == "ing" },
                 "'I am do' offers 'ing'")

        let unconstrained = lexicon.suggest(context("I do", "do"))
        s.expect(unconstrained.isEmpty,
                 "'I do' has nothing to disambiguate with, so the floor holds at three")
    }

    s.test("a near-certain one-letter completion now reaches the screen") {
        // "I will conside" -> "consider": p=0.95 and one character. Under the old
        // full-keystroke Tab cost this scored exactly zero and was unshowable.
        let engine = SuggestionEngine()
        engine.register(SystemLexicon())
        let best = engine.bestCandidate(for: context("I will conside", "conside"))
        s.expectEqual(best?.text, "r", "the base form after a modal is offered")
    }
}
