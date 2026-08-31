import Foundation
import TypeAheadCore

func runContextReaderTests(_ s: Suite) {
    s.report("ContextReader")

    s.test("trailing word is empty after a separator") {
        // An empty prefix is how the engine knows to offer a next word rather
        // than glue a completion onto a half-typed token.
        s.expectEqual(ContextReader.trailingWord(of: "kaise "), "", "after a space")
        s.expectEqual(ContextReader.trailingWord(of: "hello, "), "", "after punctuation")
        s.expectEqual(ContextReader.trailingWord(of: ""), "", "empty context")
    }

    s.test("trailing word finds a partial token") {
        s.expectEqual(ContextReader.trailingWord(of: "I will recei"), "recei", "mid-word")
        s.expectEqual(ContextReader.trailingWord(of: "recei"), "recei", "at the start of input")
    }

    s.test("an apostrophe stays inside the word") {
        s.expectEqual(ContextReader.trailingWord(of: "don'"), "don'", "contraction held together")
    }

    s.test("Devanagari words survive word splitting") {
        // Devanagari matras are combining marks, not letters. Splitting on
        // letters alone would cut words mid-syllable and poison the n-grams.
        s.expectEqual(ContextReader.trailingWord(of: "मैं कैसे"), "कैसे", "matras kept with the word")
        s.expectEqual(ContextReader.trailingWord(of: "मैं कैसे "), "", "separator still separates")
    }

    s.test("Latin Hinglish is just a word like any other") {
        s.expectEqual(ContextReader.trailingWord(of: "kaise ho bha"), "bha", "no special casing")
    }

    s.test("the shadow buffer tracks typing and backspace") {
        let reader = ContextReader()
        reader.noteTyped("hel")
        reader.noteBackspace()
        reader.noteTyped("llo")

        // Read falls back to the shadow buffer when no app has focus in tests.
        let context = reader.read()
        s.expect(!context.isAuthoritative, "fallback path is marked non-authoritative")
        s.expectEqual(context.textBeforeCaret, "hello", "buffer content")
        s.expectEqual(context.currentWordPrefix, "hello", "prefix derived from buffer")
    }

    s.test("invalidating the shadow buffer clears stale context") {
        // Stale context produces confidently wrong suggestions, which is worse
        // than no suggestion at all.
        let reader = ContextReader()
        reader.noteTyped("hello")
        reader.invalidateShadow()

        s.expectEqual(reader.read().textBeforeCaret, "", "cleared on caret displacement")
    }

    s.test("the shadow buffer is bounded") {
        let reader = ContextReader()
        reader.noteTyped(String(repeating: "a", count: 500))

        s.expectEqual(reader.read().textBeforeCaret.count,
                      ContextReader.maxContextChars,
                      "capped at the context limit")
    }
}
