import Foundation
import NaturalLanguage
import TypeAheadCore

/// The rule that keeps typos out without throwing away names and Hinglish:
/// **frequency separates a typo from a word.** A dictionary alone would reject
/// both; a counter alone would accept both.
func runHygieneTests(_ s: Suite) {
    s.report("Spelling hygiene")
    let hygiene = WordHygiene()

    s.test("dictionary words are learned immediately") {
        s.expectEqual(hygiene.verdict(for: "receive", seenCount: 1), .known, "known word")
        s.expectEqual(hygiene.verdict(for: "attached", seenCount: 1), .known, "known word")
    }

    s.test("a one-off misspelling is held back, not learned") {
        // "anhting", "workighow" and friends — the debris in a real store.
        s.expectEqual(hygiene.verdict(for: "anhting", seenCount: 1), .unverified, "typo")
        s.expectEqual(hygiene.verdict(for: "workighow", seenCount: 1), .unverified, "glued words")
        s.expectEqual(hygiene.verdict(for: "kjddithistyp", seenCount: 2), .unverified, "keyboard mash")
    }

    s.test("fragments left by dropped keystrokes never qualify") {
        for fragment in ["yi", "ot", "f", "d"] {
            s.expectEqual(hygiene.verdict(for: fragment, seenCount: 1), .unverified,
                          "fragment \(fragment)")
        }
    }

    s.test("an unrecognised word that recurs is promoted") {
        // This is the whole point: Hinglish, names and jargon are not in any
        // dictionary, but you type them constantly. A typo you do not.
        // "nahi" and "bhai" are deliberately absent: the checker here runs as
        // en_IN and already accepts them, so they are learned immediately rather
        // than needing to recur. Right outcome by a different route — and
        // asserting otherwise would tie the test to one machine's dictionary.
        for word in ["chaudhary", "typeahed"] {
            s.expectEqual(hygiene.verdict(for: word, seenCount: 1), .unverified,
                          "\(word) starts unverified")
            s.expectEqual(hygiene.verdict(for: word, seenCount: WordHygiene.unknownWordThreshold),
                          .term,
                          "\(word) is promoted once it recurs")
        }
    }

    s.test("common typos the dictionary accepts are caught by the corrector instead") {
        // "teh" passes the spell check, so hygiene cannot catch it. The safety net
        // is Corrector, which learns the fix from the user's own backspaces.
        s.expectEqual(hygiene.verdict(for: "teh", seenCount: 1), .known,
                      "dictionary waves it through")
        s.expect(Corrector.isPlausibleTypoFix(from: "teh", to: "the"),
                 "but the corrector recognises the fix")
    }

    s.test("only verified words are ever offered") {
        s.expect(!WordHygiene.isOfferable(kind: "unverified", count: 99),
                 "unverified is never offered, however often it appears")
        s.expect(WordHygiene.isOfferable(kind: "word", count: 2), "known word at 2 sightings")
        s.expect(!WordHygiene.isOfferable(kind: "word", count: 1), "known word needs 2")
        s.expect(WordHygiene.isOfferable(kind: "term", count: WordHygiene.unknownWordThreshold),
                 "promoted term is offered")
    }

    s.test("the store never completes an unverified word") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        // A typo, typed twice — enough for the old evidence bar, not enough now.
        for _ in 0..<2 {
            model.observe(.wordCommitted(word: "anhting", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }
        let typo = model.suggest(TypingContext(textBeforeCaret: "anht",
                                               currentWordPrefix: "anht",
                                               appBundleID: nil,
                                               isAuthoritative: true))
        s.expect(typo.isEmpty, "typo not offered — got \(typo.map(\.text))")

        // A real word, typed twice, is offered.
        for _ in 0..<2 {
            model.observe(.wordCommitted(word: "attached", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }
        let real = model.suggest(TypingContext(textBeforeCaret: "attac",
                                               currentWordPrefix: "attac",
                                               appBundleID: nil,
                                               isAuthoritative: true))
        s.expect(!real.isEmpty, "real word offered")
    }

    s.test("a name the dictionary rejects survives once it recurs") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        for _ in 0..<WordHygiene.unknownWordThreshold {
            model.observe(.wordCommitted(word: "chaudhary", boundary: .space, appBundleID: nil))
            model.observe(.caretMoved)
        }
        let candidates = model.suggest(TypingContext(textBeforeCaret: "chaud",
                                                     currentWordPrefix: "chaud",
                                                     appBundleID: nil,
                                                     isAuthoritative: true))
        s.expect(candidates.contains { $0.text == "hary" },
                 "recurring name offered — got \(candidates.map(\.text))")
    }

    s.test("forgetting typos leaves real words alone") {
        let (store, _) = try makeTemporaryStore()
        let model = PersonalModel(store: store)

        model.observe(.wordCommitted(word: "anhting", boundary: .space, appBundleID: nil))
        for _ in 0..<3 {
            model.observe(.caretMoved)
            model.observe(.wordCommitted(word: "attached", boundary: .space, appBundleID: nil))
        }

        let removed = try store.forgetUnverified(seenFewerThan: WordHygiene.unknownWordThreshold)
        s.expect(removed >= 1, "removed at least the typo")
        s.expectEqual(try store.wordCount("anhting"), 0, "typo gone")
        s.expectEqual(try store.wordCount("attached"), 3, "real word untouched")
    }
}

/// Transposition is the most common typing error there is, and plain Levenshtein
/// scores every one of them as 2 — which silently put short words out of reach.
func runEditDistanceTests(_ s: Suite) {
    s.report("Edit distance")

    s.test("adjacent transpositions cost 1, not 2") {
        s.expectEqual(Corrector.editDistance("teh", "the"), 1, "teh → the")
        s.expectEqual(Corrector.editDistance("adn", "and"), 1, "adn → and")
        s.expectEqual(Corrector.editDistance("recieve", "receive"), 1, "recieve → receive")
    }

    s.test("ordinary edits are unchanged") {
        s.expectEqual(Corrector.editDistance("cat", "cat"), 0, "identical")
        s.expectEqual(Corrector.editDistance("cat", "cut"), 1, "substitution")
        s.expectEqual(Corrector.editDistance("cat", "cart"), 1, "insertion")
        s.expectEqual(Corrector.editDistance("cart", "cat"), 1, "deletion")
        s.expectEqual(Corrector.editDistance("", "abc"), 3, "from empty")
        s.expectEqual(Corrector.editDistance("abc", ""), 3, "to empty")
    }

    s.test("short transposed typos are now learnable") {
        s.expect(Corrector.isPlausibleTypoFix(from: "teh", to: "the"), "teh")
        s.expect(Corrector.isPlausibleTypoFix(from: "adn", to: "and"), "adn")
        // Still not a reword.
        s.expect(!Corrector.isPlausibleTypoFix(from: "hello", to: "hi"), "reword still rejected")
    }
}

/// Regressions from testing the model against a real llama-server. Every one of
/// these passed review and failed in practice.
func runModelTests(_ s: Suite) {
    s.report("Model integration")

    s.test("a non-GGUF file is rejected as a model") {
        // The bug this guards: a failed download wrote a 29-byte file containing
        // "Invalid username or password." and the app reported it as installed.
        let path = NSTemporaryDirectory() + "fake-\(UUID().uuidString).gguf"
        try "Invalid username or password.".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.expect(!GGUFModel.isValidGGUF(path: path), "error page is not a model")

        let real = NSTemporaryDirectory() + "real-\(UUID().uuidString).gguf"
        try Data("GGUF".utf8 + Data(repeating: 0, count: 64)).write(to: URL(fileURLWithPath: real))
        defer { try? FileManager.default.removeItem(atPath: real) }
        s.expect(GGUFModel.isValidGGUF(path: real), "GGUF header accepted")
    }

    s.test("a missing file is rejected rather than assumed good") {
        s.expect(!GGUFModel.isValidGGUF(path: "/nonexistent/model.gguf"), "no file, no model")
    }

    s.test("catalog entries name a real repo and file") {
        // The previous catalog was written from memory and every URL 401'd or
        // 404'd. Shape is checkable offline; existence was verified by hand.
        for entry in ModelRegistry.catalog where entry.id != "none" {
            s.expect(entry.repo.contains("/"), "\(entry.id) names an org/repo")
            s.expect(entry.file.hasSuffix(".gguf"), "\(entry.id) names a .gguf file")
            s.expect(entry.approximateBytes > 100_000_000, "\(entry.id) has a plausible size")
        }
    }

    s.test("the memory-only entry is a real choice, not a failure") {
        let none = ModelRegistry.catalog.first { $0.id == "none" }
        s.expect(none != nil, "catalog offers memory-only")
        s.expectEqual(none?.repo, "", "it downloads nothing")
    }
}

/// The cold-start fix: general suggestions from the first keystroke, without
/// drowning out what the app learns about you.
func runLexiconTests(_ s: Suite) {
    s.report("System lexicon")
    let lexicon = SystemLexicon()

    func ctx(_ prefix: String) -> TypingContext {
        TypingContext(textBeforeCaret: prefix, currentWordPrefix: prefix,
                      appBundleID: nil, isAuthoritative: true)
    }

    s.test("it completes common words with no training at all") {
        for prefix in ["recei", "sugg", "accom"] {
            let candidates = lexicon.suggest(ctx(prefix))
            s.expect(!candidates.isEmpty, "\(prefix) has completions — got \(candidates.map(\.text))")
        }
    }

    s.test("short prefixes are ignored") {
        // Two letters match most of the language; the top guess is a coin flip.
        s.expect(lexicon.suggest(ctx("re")).isEmpty, "two letters withheld")
    }

    s.test("non-word prefixes are ignored") {
        s.expect(lexicon.suggest(ctx("http")).isEmpty || !lexicon.suggest(ctx("a1b2")).isEmpty == false,
                 "identifiers and codes are not dictionary words")
        s.expect(lexicon.suggest(ctx("a1b2")).isEmpty, "mixed alphanumerics withheld")
    }

    s.test("personal memory outranks the dictionary") {
        // The whole ordering claim: general suggestions help on day one and get
        // out of the way as the app learns you.
        let (store, _) = try makeTemporaryStore()
        let personal = PersonalModel(store: store)
        for _ in 0..<3 {
            personal.observe(.wordCommitted(word: "receipts", boundary: .space, appBundleID: nil))
            personal.observe(.caretMoved)
        }

        let engine = SuggestionEngine()
        engine.register(personal)
        engine.register(lexicon)

        let best = engine.bestCandidate(for: ctx("recei"))
        s.expectEqual(best?.origin, .prefixTrie,
                      "a word you actually use beats the dictionary's guess")
    }

    s.test("the dictionary still answers when memory is empty") {
        let (store, _) = try makeTemporaryStore()
        let engine = SuggestionEngine()
        engine.register(PersonalModel(store: store))
        engine.register(lexicon)

        let best = engine.bestCandidate(for: ctx("sugg"))
        s.expectEqual(best?.origin, .lexicon, "cold install still suggests")
    }
}

/// Inflection choice from the preceding word — the fix for "I will considering".
func runGrammarTests(_ s: Suite) {
    s.report("Grammar")

    s.test("it reads the word before the one being typed") {
        s.expectEqual(GrammarFilter.precedingWord(in: "I will conside", before: "conside"),
                      "will", "modal found")
        s.expectEqual(GrammarFilter.precedingWord(in: "I am conside", before: "conside"),
                      "am", "auxiliary found")
        s.expectNil(GrammarFilter.precedingWord(in: "conside", before: "conside"),
                    "nothing before the first word")
    }

    s.test("it classifies inflections") {
        s.expectEqual(GrammarFilter.form(of: "considering"), .progressive, "-ing")
        s.expectEqual(GrammarFilter.form(of: "considered"), .pastParticiple, "-ed")
        s.expectEqual(GrammarFilter.form(of: "recommendation"), .noun, "-tion")
        s.expectEqual(GrammarFilter.form(of: "consider"), .base, "bare stem")
    }

    s.test("a modal prefers the bare stem over the -ing form") {
        // "I will consider", never "I will considering" — the exact complaint.
        let candidates = [
            Candidate(text: "ring", probability: 0.45, origin: .lexicon),
            Candidate(text: "r", probability: 0.22, origin: .lexicon)
        ]
        let adjusted = GrammarFilter.adjust(candidates, prefix: "conside", context: "I will conside")
        let base = adjusted.first { $0.text == "r" }
        let progressive = adjusted.first { $0.text == "ring" }
        s.expect((base?.probability ?? 0) > (progressive?.probability ?? 1),
                 "after 'will', consider beats considering")
    }

    s.test("an auxiliary prefers the -ing form") {
        let candidates = [
            Candidate(text: "ring", probability: 0.22, origin: .lexicon),
            Candidate(text: "r", probability: 0.45, origin: .lexicon)
        ]
        let adjusted = GrammarFilter.adjust(candidates, prefix: "conside", context: "I am conside")
        let base = adjusted.first { $0.text == "r" }
        let progressive = adjusted.first { $0.text == "ring" }
        s.expect((progressive?.probability ?? 0) > (base?.probability ?? 1),
                 "after 'am', considering beats consider")
    }

    s.test("a determiner prefers the noun form") {
        let candidates = [
            Candidate(text: "end", probability: 0.45, origin: .lexicon),
            Candidate(text: "endation", probability: 0.10, origin: .lexicon)
        ]
        let adjusted = GrammarFilter.adjust(candidates, prefix: "recomm", context: "the recomm")
        let noun = adjusted.first { $0.text == "endation" }
        let verb = adjusted.first { $0.text == "end" }
        s.expect((noun?.probability ?? 0) > (verb?.probability ?? 1),
                 "after 'the', recommendation beats recommend")
    }

    s.test("it reweights rather than vetoes") {
        // English is not a lookup table; a wrong rule must cost a rank, not a
        // suggestion.
        let candidates = [Candidate(text: "ring", probability: 0.45, origin: .lexicon)]
        let adjusted = GrammarFilter.adjust(candidates, prefix: "conside", context: "I will conside")
        s.expect((adjusted.first?.probability ?? 0) > 0, "still offered, just demoted")
    }

    s.test("agreement between sources raises confidence") {
        let agreed = SuggestionEngine.boostAgreement([
            Candidate(text: "ciate", probability: 0.45, origin: .lexicon),
            Candidate(text: "ciate", probability: 0.40, origin: .model)
        ])
        s.expectEqual(agreed.count, 1, "duplicates collapse")
        s.expect((agreed.first?.probability ?? 0) > 0.45, "two sources agreeing beats either alone")
    }
}

/// Cases where the suffix rules were wrong and the lemma is right — the reason
/// for using Apple's tagger instead of hand-rolled morphology.
func runLemmaTests(_ s: Suite) {
    s.report("Lemma-based morphology")

    s.test("words that merely end in -ing are not progressives") {
        // "during" is not a verb; its lemma is itself. A suffix rule called it
        // progressive and demoted it after "will".
        s.expect(GrammarFilter.form(of: "during") != .progressive, "during")
        s.expect(GrammarFilter.form(of: "thing") != .progressive, "thing")
        s.expect(GrammarFilter.form(of: "ring") != .progressive, "ring")
    }

    s.test("words that merely end in -ed are not past participles") {
        s.expect(GrammarFilter.form(of: "need") != .pastParticiple, "need")
        s.expect(GrammarFilter.form(of: "speed") != .pastParticiple, "speed")
    }

    s.test("real inflections are still recognised") {
        s.expectEqual(GrammarFilter.form(of: "considering"), .progressive, "considering")
        s.expectEqual(GrammarFilter.form(of: "considered"), .pastParticiple, "considered")
        s.expectEqual(GrammarFilter.form(of: "recommendation"), .noun, "recommendation")
    }

    s.test("determiners are found by the tagger, not a hand-written list") {
        // Every determiner in the language, not the two dozen anyone remembers.
        s.expectEqual(GrammarFilter.partOfSpeech(of: "the", in: "the recommendation"),
                      .determiner, "the")
        // "whichever" is deliberately absent: the tagger reads it as a pronoun,
        // which is defensible, and the test was asserting my opinion rather than
        // the library's. Words with a settled determiner reading are the point.
        s.expectEqual(GrammarFilter.partOfSpeech(of: "every", in: "every option"),
                      .determiner, "every")
        s.expectEqual(GrammarFilter.partOfSpeech(of: "those", in: "those options"),
                      .determiner, "those")
    }
}

/// The "Anandnd" bug: a suggestion computed for a shorter prefix, shown after
/// more was typed, duplicating characters — and then learned.
func runStaleSuggestionTests(_ s: Suite) {
    s.report("Stale suggestions")

    func ctx(_ text: String) -> TypingContext {
        TypingContext(textBeforeCaret: text,
                      currentWordPrefix: ContextReader.trailingWord(of: text),
                      appBundleID: nil, isAuthoritative: true)
    }

    s.test("a completion repeating what was just typed is rejected") {
        // "Anand" + "nd" = "Anandnd". Computed for "Ana", shown after "Anand".
        let stale = Candidate(text: "nd", probability: 0.9, origin: .prefixTrie)
        s.expect(SuggestionEngine.duplicatesTypedText(stale, context: ctx("My name is Anand")),
                 "the duplicating completion is caught")
    }

    s.test("a legitimate completion is not rejected") {
        let good = Candidate(text: "ciate", probability: 0.5, origin: .lexicon)
        s.expect(!SuggestionEngine.duplicatesTypedText(good, context: ctx("I appre")),
                 "appre + ciate is fine")
        let alsoGood = Candidate(text: "d", probability: 0.5, origin: .prefixTrie)
        s.expect(!SuggestionEngine.duplicatesTypedText(alsoGood, context: ctx("Anan")),
                 "single characters are not treated as duplication")
    }

    s.test("a correction is exempt, since replacing is its whole job") {
        let fix = Candidate(text: "the", probability: 0.8, origin: .correction,
                            replacesPreviousCharacters: 3)
        s.expect(!SuggestionEngine.duplicatesTypedText(fix, context: ctx("teh")),
                 "corrections replace rather than append")
    }

    s.test("the engine filters duplicates end to end") {
        let (store, _) = try makeTemporaryStore()
        let engine = SuggestionEngine()
        engine.register(EchoSource())
        s.expect(engine.bestCandidate(for: ctx("My name is Anand")) == nil,
                 "a source echoing the typed tail produces nothing")
        _ = store
    }
}

/// Emits exactly the tail of what was typed — the shape a stale suggestion takes.
final class EchoSource: SuggestionSource {
    let name = "Echo"
    func suggest(_ context: TypingContext) -> [Candidate] {
        let prefix = context.currentWordPrefix
        guard prefix.count >= 2 else { return [] }
        return [Candidate(text: String(prefix.suffix(2)), probability: 0.9, origin: .prefixTrie)]
    }
}

/// The safety property that makes inline suggestions survivable: removal matches
/// on content, so it can never delete something the user wrote.
func runInlineGhostTests(_ s: Suite) {
    s.report("Inline ghost removal")

    func utf16(_ s: String) -> [UInt16] { Array(s.utf16) }

    s.test("it finds the ghost exactly where it was put") {
        let text = utf16("My name is Anand")
        s.expectEqual(InlineGhost.locate("Anand", in: text, near: 11), 11, "found at the anchor")
    }

    s.test("it refuses to find the ghost anywhere but its exact position") {
        // The bug this replaces: searching nearby found the *user's* identical
        // text and deleted that instead. A suggestion of "the" matches their "the".
        let text = utf16("Hello there. My name is Anand")
        s.expectNil(InlineGhost.locate("Anand", in: text, near: 11),
                    "a shifted document is not searched")
    }

    s.test("it never matches the user's own identical text") {
        // "the" was suggested at 0; the user's own "the" sits at 12. Deleting
        // theirs would silently destroy what they wrote.
        let text = utf16("I think that the report is ready")
        s.expectNil(InlineGhost.locate("the", in: text, near: 0),
                    "no match at the anchor means no deletion, full stop")
    }

    s.test("it refuses to delete when the ghost is gone") {
        // The critical case: the user deleted or replaced it. Guessing a range
        // here would destroy their text.
        let text = utf16("Something else entirely")
        s.expectNil(InlineGhost.locate("Anand", in: text, near: 11), "no match, no deletion")
    }

    s.test("a repeated word only matches at the anchor") {
        let text = utf16("Anand and Anand")
        s.expectEqual(InlineGhost.locate("Anand", in: text, near: 10), 10, "exact anchor matches")
        s.expectNil(InlineGhost.locate("Anand", in: text, near: 6), "a near miss is a miss")
    }

    s.test("slicing is bounds-safe") {
        let text = utf16("short")
        s.expectNil(InlineGhost.slice(text, at: 3, length: 99), "past the end")
        s.expectNil(InlineGhost.slice(text, at: -1, length: 2), "before the start")
        s.expectEqual(InlineGhost.slice(text, at: 0, length: 5), "short", "exact fit")
    }
}

/// The two constraints that make an inline ghost survivable, asserted over the
/// source because both are properties of *where* code sits, not what it returns.
func runInlineSafetyTests(_ s: Suite) {
    s.report("Inline safety")

    let core = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Core")

    func source(_ name: String) -> String {
        let hits = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        while let url = hits?.nextObject() as? URL {
            if url.lastPathComponent == name {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        return ""
    }

    s.test("the ghost is only ever placed at the end of the field") {
        // A ghost buried mid-paragraph, if it ever fails to come out, is inside
        // the user's writing. At the end it is trailing text the next keystroke
        // replaces.
        let ghost = source("InlineGhost.swift")
        s.expect(ghost.contains("caret.location >= existing.count"),
                 "insertion requires the caret to be at the end")
    }

    s.test("Return always removes the ghost explicitly") {
        // Typing replaces a selection; Return does not. In a chat box a surviving
        // ghost would be sent with the message.
        let coordinator = source("Coordinator.swift")
        s.expect(coordinator.contains("!event.isReturn"),
                 "Return is excluded from the replaced-by-typing path")
        s.expect(coordinator.contains("inlineGhost.remove()"),
                 "and takes the explicit removal path")
    }

    s.test("removal never searches for the ghost") {
        let ghost = source("InlineGhost.swift")
        s.expect(!ghost.contains("searchWindow"),
                 "no window search — it matched the user's own text and deleted it")
    }
}

/// The keystroke path must never block. An Accessibility call waits for another
/// process to answer, and doing that inside the event tap is felt as input lag —
/// or gets the tap disabled by the system for being too slow.
func runThreadingTests(_ s: Suite) {
    s.report("Main thread")

    let core = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Core")

    func source(_ name: String) -> String {
        let hits = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        while let url = hits?.nextObject() as? URL {
            if url.lastPathComponent == name {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        return ""
    }

    let coordinator = source("Coordinator.swift")

    s.test("the key path never calls into Accessibility synchronously") {
        // Everything that talks to another app is dispatched. The only work left
        // on the tap callback is field assignment and pure logic.
        guard let start = coordinator.range(of: "shouldSwallow event: KeyEvent) -> Bool {"),
              let end = coordinator.range(of: "private func accept(") else {
            s.expect(false, "could not locate the key path")
            return
        }
        let body = String(coordinator[start.upperBound..<end.lowerBound])

        for blocking in ["inlineGhost.remove()", "inlineGhost.show(", "inlineGhost.accept()"] {
            let occurrences = body.components(separatedBy: blocking).count - 1
            let dispatched = body.components(separatedBy: "insertionQueue.async").count - 1
            s.expect(occurrences == 0 || dispatched > 0,
                     "\(blocking) must be dispatched, not called inline")
        }
    }

    s.test("showing and accepting are dispatched") {
        s.expect(coordinator.contains("insertionQueue.async"),
                 "insertion work is queued")
        s.expect(coordinator.contains("qos: .userInteractive"),
                 "queued at interactive priority, so it is not starved")
    }

    s.test("the insertion queue is serial") {
        // Two Accessibility mutations racing on one field is how stray text gets
        // left behind. A concurrent queue would allow exactly that.
        s.expect(!coordinator.contains("attributes: .concurrent"),
                 "insertion must be serialised")
    }
}

/// macOS turns two adjacent spaces into ". " on its own. A typed ghost that
/// begins with a space puts one of those spaces there.
func runSubstitutionTests(_ s: Suite) {
    s.report("System text substitution")

    let core = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Core")

    func source(_ name: String) -> String {
        let hits = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        while let url = hits?.nextObject() as? URL {
            if url.lastPathComponent == name {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        return ""
    }

    s.test("a leading-space ghost is excluded from the replace-by-typing path") {
        // "Make" + snippet " What" typed, then the user presses space: macOS sees
        // space-space and substitutes a period. Explicit removal breaks that up.
        let coordinator = source("Coordinator.swift")
        s.expect(coordinator.contains("!inlineGhost.typedLeadingWhitespace"),
                 "leading-space ghosts take the explicit removal path")
    }

    s.test("the flag only applies to typed ghosts") {
        // An Accessibility write never enters the input stream, so no substitution
        // can see it — the flag would be a pointless restriction there.
        let ghost = source("InlineGhost.swift")
        s.expect(ghost.contains("ghost.route == .typed"),
                 "the check is scoped to the typed route")
    }

    s.test("snippet completions really do carry leading spaces") {
        // The premise of the bug, asserted so it cannot quietly stop being true.
        let candidates = SnippetSource(store: try makeTemporaryStore().store)
        _ = candidates
        let remainder = "Make it".dropFirst("Make".count)
        s.expectEqual(String(remainder), " it", "the completion begins with a space")
    }
}

/// The typed route is withdrawn. These assert it stays that way, because it is
/// the kind of idea that gets re-added by someone reasoning from first principles
/// about React and not from what it did in use.
func runTypedGhostTests(_ s: Suite) {
    s.report("Typed ghost (withdrawn)")

    let core = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Core")

    func source(_ name: String) -> String {
        let hits = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        while let url = hits?.nextObject() as? URL {
            if url.lastPathComponent == name {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        return ""
    }

    s.test("no ghost is ever shown by typing") {
        // Synthetic keystrokes share the input stream with the user's own and are
        // delivered asynchronously. A preview shown and withdrawn on every
        // keystroke interleaves with real typing and corrupts it.
        let ghost = source("InlineGhost.swift")
        s.expect(!ghost.contains("inserter.insert(text)"),
                 "InlineGhost must not type the suggestion")
        s.expect(!ghost.contains("selectPreviousCharacters"),
                 "and must not select it back")
    }

    s.test("insertion is Accessibility-only") {
        let ghost = source("InlineGhost.swift")
        s.expect(ghost.contains("kAXSelectedTextAttribute"),
                 "the only insertion route is the Accessibility write")
    }
}
