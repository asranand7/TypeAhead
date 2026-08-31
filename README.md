# TypeAhead

A local predictor that works in every text box on macOS and learns how you write.
Suggestions appear greyed out next to the caret; **Tab** takes them. One goal:
**type as little as possible.**

Runs in the background from login, with no Dock icon and no window — just a menu
bar item. English, Hindi and Hinglish, because that is how you write; the
languages are a requirement, not the point.

## The two rules

**1. The app never changes your text unless you press Tab.**
Predictions, corrections and snippets all appear as ghost text and are accepted
the same way. Return, Space, Enter, arrows — none of them accept. Enforced by a
test asserting text insertion has exactly one call site, reachable only from the
Tab handler.

**How much one Tab takes.** The pill always shows the *whole* suggestion — you
cannot judge an offer you cannot see, and "let" tells you nothing about whether
the phrase is "let me know if that works" or "let's talk Friday". What a single
press takes is a separate question, and it depends on where the suggestion came
from. A phrase is taken one word per press, repeatably, so four words right and
a fifth wrong is still worth four words. Something recalled verbatim — your email
address, a correction — lands whole on one press, because half an email address
is not a smaller win, it is a mess.

**2. The memory owns you. The model is a commodity.**
Everything personal lives in the memory store, never in model weights — so a model
can be swapped or deleted without costing you anything. The app **never
fine-tunes**, works with no model installed, and its export contains nothing
model-specific.

## Two front-ends, one memory

| | Where suggestions appear | Trade-off |
|---|---|---|
| **Input method** (`./build-im.sh`) | **Inside the text field**, at the caret | You pick it from the Input menu; it becomes your keyboard input source |
| **Menu-bar app** (`./build.sh`) | Floating pill beside the caret | Always on in the background; position depends on apps answering an Accessibility query many ignore |

Both share the same store, ranking, corrections and export file. Install either or
both — what one learns, the other knows.

The input method is the better experience: the host app draws the suggestion
itself, so it is genuinely inline and always in the right place. It sits in the
path of every keystroke, so it is built to **pass through everything it does not
own** — only Tab and Escape are ever consumed, and only while a suggestion is
showing. A bug there degrades to "no suggestions", never to "cannot type".

## Install

```bash
./scripts/make-signing-cert.sh && ./build.sh    # menu-bar app
./build-im.sh                                    # input method
```

Then turn the input method on:
**System Settings › Keyboard › Text Input › Input Sources › Edit… › +
→ English → TypeAhead → Add**, and pick it from the input menu (⌃Space).

Run the cert script **first, once**. macOS keys the Accessibility permission to
the code signature, so ad-hoc signing drops the grant on *every rebuild*:

| | designated requirement | survives rebuild? |
|---|---|---|
| identity-signed | `certificate leaf = H"1a3b…"` | **yes** |
| ad-hoc | `cdhash H"2e76…"` | no |

Note that `security find-identity -v -p codesigning` reports **"0 valid
identities found"** even when this works — it lists only *trusted* certificates,
and a self-signed one is not trusted. `codesign` uses it fine. `build.sh` checks
with `find-certificate` instead.

Then grant Accessibility once, in System Settings › Privacy & Security.

### Optional: a model

```bash
brew install llama.cpp
```

Then pick one from the menu bar. Entirely optional — the half that learns *your*
writing needs no model at all, and is the stronger half for anything you type
often.

### Tests

```bash
swift run TypeAheadTests
```

423 assertions. A plain executable, not XCTest, which ships only with Xcode.

## Architecture

```
KeyTap ──▶ Coordinator ──▶ ContextReader ──▶ SuggestionEngine ──▶ Ranker
              │                                     ▲
              │                                     │  register()
              ├──▶ AcceptanceController      [ SuggestionSource ]
              │      (the only path to text)   identity · corrections · snippets
              │                                 personal n-gram · GGUF model
              ├──▶ Inserter    (the only writer)
              ├──▶ SuggestionOverlay
              └──▶ TypingSignalBus ──▶ [ TypingObserver ]
                                        personal · miner · detector ·
                                        corrector · savings
```

Two extension points carry every feature. Adding one of the seven phases meant
registering a `SuggestionSource` or a `TypingObserver` — `Coordinator` and
`SuggestionEngine` never changed after phase 1.

### The objective function

```
score = Σᵢ P(accepted) · qᵒʳⁱᵍⁱⁿ ⁱ⁻¹ · (lengthᵢ − 1)
```

Ranking by probability alone would always prefer the short, safe, nearly
worthless suggestion. This prefers the phrase at 40% confidence over the
3-character word at 90%. For corrections, `keystrokes_saved` includes the
retyping you are spared — which is why a 7-character fix outranks a 4-character
completion.

The sum is over the words of a phrase, because a phrase is not accepted whole —
you take a prefix and stop where it stops being right. Each word is discounted by
`q`, the odds of getting one word further, which depends on the evidence: 0.8 for
a phrase you have typed before verbatim, 0.45 for a chain of n-gram guesses whose
error compounds. The weights sum to `1/(1−q)`, so a phrase can be worth at most
five single words however long it runs.

Without that cap, expected savings scaled with raw character count and long
suggestions won by construction. They did: in a real store the snippet tier was
the most-shown source and had never once been accepted.

**Confidence is calibrated against acceptance.** Each source invents its own
probability on its own scale, so every origin is rescaled by how often it is
actually taken, relative to the average origin — a redistribution, never an
across-the-board cut, because the savings gate is absolute and deflating
everything would silence the app.

### The memory, in four tiers

| Tier | Holds | Learned by |
|---|---|---|
| Identity | emails, phone | seeded from your contact card, or after 3 sightings |
| People & terms | names, jargon, projects | automatically |
| Snippets | phrases of 3+ words you repeat | mined after 2 repeats |
| Statistics | n-grams, per-app | every word |

Plus typo pairs learned from your own backspaces, and acceptance feedback.

## Export / import

One `.tamem` file, which is a **zip** you can open:

```
identity.json      readable    manifest.json     schema, machine, date
vocab.json         readable    stats.sqlite      n-gram counts (opaque)
snippets.json      readable
corrections.json   readable
```

No weights, no tokenizer ids. Export from a Mac running Qwen, import on one
running Gemma or nothing at all.

**Import merges, never overwrites.** Counts are summed, vocabularies unioned —
so carrying memory to a second Mac does not erase what that Mac already learned,
and syncing back does not erase the first. **Identity conflicts are the
exception:** two different phone numbers are both kept and flagged, because
silently picking a winner is the one outcome you could not detect or undo.

Export goes through a review sheet listing exactly what is about to leave the
machine, with a switch to drop the identity tier.

## Verified

423 assertions, `swift run TypeAheadTests`:

- **74.4% keystrokes saved** on the test corpus — an upper bound, since that
  corpus deliberately repeats itself and the simulated typist accepts every
  correct suggestion. Real writing will be lower.
- ranking order, savings gate, tie-breaking, determinism
- the Tab state machine, **Tab passthrough when nothing is pending**, and that
  *no other key accepts*
- word-wise phrase acceptance and every way it can be cancelled
- learning, per-app separation, Devanagari, snippet promotion, identity detection
- **corrections learned from backspaces**, and rewording *not* mistaken for typos
- **vocabulary protection** — your own words are never "corrected"
- export → wipe → import round trip; **counts summed, not replaced**
- **n-gram id remapping** across databases with different vocabularies
- **identity conflicts kept and flagged**
- rule 2: export on model A imports on model B; deleting the model leaves a
  working app; hot-swapping leaves memory byte-identical
- rules 1 and 2 asserted over the source tree

### Not yet verified — the app matrix

Accessibility is refused by some apps; the shadow keystroke buffer covers those,
less reliably. This needs a human at a keyboard.

| App | AX context | Overlay at caret | Tab accept | Notes |
|---|---|---|---|---|
| TextEdit | | | | |
| Notes | | | | |
| Safari | | | | |
| Chrome | | | | |
| Slack | | | | |
| VS Code | | | | |
| Terminal | | | | |

Latency against a real model is also unmeasured — no model is installed, and the
`ModelComparison` harness exists to measure it once one is.

## Menu bar

- **Suggestions On/Off** — and ⌥⇧Space toggles it from anywhere
- **Start at login** — on by default
- Keystrokes saved, total and this session
- **Model** — catalog, download, hot-swap, "Add model…" for any local GGUF
- **Memory** — review what it knows, export, import, pause learning
- **This app** — never suggest in the app you are currently in

Pausing *learning* and pausing *suggestions* are separate switches: "stop
suggesting but keep learning" and "keep suggesting but stop learning" are both
things you want, and one control could not express either.
