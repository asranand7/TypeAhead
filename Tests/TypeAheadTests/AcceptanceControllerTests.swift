import Carbon.HIToolbox
import CoreGraphics
import Foundation
import TypeAheadCore

func runAcceptanceControllerTests(_ s: Suite) {
    s.report("AcceptanceController")

    func key(_ code: Int, characters: String = "", modifiers: CGEventFlags = []) -> KeyEvent {
        KeyEvent(keyCode: Int64(code), characters: characters, modifiers: modifiers)
    }
    let tab = key(kVK_Tab)
    let escape = key(kVK_Escape)
    func letter(_ character: String) -> KeyEvent { key(kVK_ANSI_A, characters: character) }

    // MARK: Tab passthrough

    s.test("Tab passes through when nothing is pending") {
        // Non-negotiable: swallowing Tab unconditionally would break form
        // navigation and editor indentation in every app on the machine.
        let controller = AcceptanceController()
        s.expectEqual(controller.handle(tab), .passThrough, "bare Tab is the app's")
    }

    s.test("Tab passes through after the suggestion is dismissed") {
        let controller = AcceptanceController()
        controller.present(Candidate(text: "ceive ", probability: 0.8, origin: .prefixTrie))
        _ = controller.handle(letter("x"))

        s.expectEqual(controller.handle(tab), .passThrough, "stale suggestion does not capture Tab")
    }

    // MARK: Single-word acceptance

    s.test("a single word is accepted whole and final") {
        let controller = AcceptanceController()
        let candidate = Candidate(text: "ceive ", probability: 0.8, origin: .prefixTrie)
        controller.present(candidate)

        s.expectEqual(controller.handle(tab),
                      .accept(text: "ceive ", candidate: candidate, isFinal: true, replaces: 0),
                      "whole word inserted")
        s.expect(!controller.hasPendingSuggestion, "state cleared after final accept")
    }

    // MARK: Two-stage phrase acceptance

    s.test("each Tab takes exactly one word, repeatably") {
        // Uniform, unlike the two-stage version this replaced: that took one word
        // on the first press and all of the rest on the second, so a five-word
        // phrase could be taken as one or five and never as three. Partial
        // correctness is the common case, and all-or-nothing threw it away.
        let controller = AcceptanceController()
        let candidate = Candidate(text: "me know if that works",
                                  probability: 0.4,
                                  origin: .ngram)
        controller.present(candidate)

        s.expectEqual(controller.displayText, "me know if that works",
                      "the pill shows the whole offer, not the next bite")

        let expected = ["me ", "know ", "if ", "that ", "works"]
        for (index, word) in expected.enumerated() {
            let isLast = index == expected.count - 1
            s.expectEqual(controller.handle(tab),
                          .accept(text: word, candidate: candidate,
                                  isFinal: isLast, replaces: 0),
                          "Tab \(index + 1) takes \(word.debugDescription)")
            if !isLast {
                s.expectEqual(controller.displayText,
                              expected[(index + 1)...].joined(),
                              "the pill shows what is left")
            }
        }
        s.expect(!controller.hasPendingSuggestion, "state cleared after the phrase")
    }

    s.test("stopping part-way keeps what was taken") {
        // The reason for word-wise acceptance: four words right and the fifth
        // wrong should still be worth four words.
        let controller = AcceptanceController()
        controller.present(Candidate(text: "me know if that works",
                                     probability: 0.4, origin: .ngram))
        _ = controller.handle(tab)
        _ = controller.handle(tab)
        s.expectEqual(controller.displayText, "if that works", "the rest is still offered")

        _ = controller.handle(letter("x"))
        s.expect(!controller.hasPendingSuggestion, "typing ends the phrase")
    }

    s.test("an atomic candidate lands whole on one Tab") {
        // An email address is verbatim recall, not a chain of guesses. Making
        // someone press Tab once per token of their own address would be absurd.
        let controller = AcceptanceController()
        let email = Candidate(text: "priya@example.com",
                              probability: 0.9, origin: .identity)
        controller.present(email)
        s.expectEqual(controller.handle(tab),
                      .accept(text: "priya@example.com", candidate: email,
                              isFinal: true, replaces: 0),
                      "the whole address on one press")
    }

    s.test("a correction pays its deletions exactly once") {
        let controller = AcceptanceController()
        let fix = Candidate(text: "receive", probability: 0.8,
                            origin: .correction, replacesPreviousCharacters: 7)
        controller.present(fix)
        s.expectEqual(controller.handle(tab),
                      .accept(text: "receive", candidate: fix, isFinal: true, replaces: 7),
                      "corrections are atomic, so the deletion happens once")
    }

    s.test("typing between Tabs cancels the extension") {
        // "An immediate second Tab, with no intervening keystroke" — the
        // intervening keystroke is what ends the phrase.
        let controller = AcceptanceController()
        controller.present(Candidate(text: "me know if that works",
                                     probability: 0.4,
                                     origin: .ngram))
        _ = controller.handle(tab)
        _ = controller.handle(letter("a"))

        s.expectEqual(controller.handle(tab), .passThrough, "extension cancelled by typing")
    }

    s.test("the extension window expires") {
        var now = Date(timeIntervalSince1970: 1000)
        let controller = AcceptanceController(extensionWindow: 4.0, now: { now })
        controller.present(Candidate(text: "regards, Anand and team",
                                     probability: 0.5,
                                     origin: .snippet))
        _ = controller.handle(tab)

        now = now.addingTimeInterval(10)
        // Stale: the user walked away and came back to a different text field.
        s.expectEqual(controller.handle(tab), .passThrough, "stale extension does not fire")
    }

    // MARK: Dismissal

    s.test("Escape dismisses and passes through") {
        let controller = AcceptanceController()
        let candidate = Candidate(text: "ceive ", probability: 0.8, origin: .prefixTrie)
        controller.present(candidate)

        s.expectEqual(controller.handle(escape), .passThroughDismissing(candidate),
                      "escape reports the rejection")
        s.expect(!controller.hasPendingSuggestion, "state cleared on escape")
    }

    s.test("a command chord leaves the suggestion standing") {
        // Cmd-S while a suggestion is up should not throw the suggestion away.
        let controller = AcceptanceController()
        controller.present(Candidate(text: "ceive ", probability: 0.8, origin: .prefixTrie))

        s.expectEqual(controller.handle(key(kVK_ANSI_S,
                                           characters: "s",
                                           modifiers: .maskCommand)),
                      .passThrough,
                      "chords are not text")
        s.expect(controller.hasPendingSuggestion, "suggestion survives a chord")
    }

    // MARK: Candidate splitting

    s.test("firstWord keeps its trailing space so the caret is ready for the next word") {
        let candidate = Candidate(text: "me know if that works",
                                  probability: 0.4,
                                  origin: .ngram)
        s.expectEqual(candidate.firstWord, "me ", "space retained")
        s.expect(candidate.isMultiWord, "phrase detected as multi-word")

        let single = Candidate(text: "ceive", probability: 0.8, origin: .prefixTrie)
        s.expectEqual(single.firstWord, "ceive", "single word is its own first word")
        s.expect(!single.isMultiWord, "single word is not multi-word")
    }
}
