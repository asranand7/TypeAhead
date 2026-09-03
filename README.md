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

### The model

```bash
brew install llama.cpp
```

Qwen3-0.6B is on by default and fetched in the background on first launch; until
it arrives the app runs on memory alone. Pick a different one, or none, from the
menu bar.

Not optional the way it used to be. For most of this project's life the default
was "No model (memory only)", which meant the shipping app had no language model
in it at all — every suggestion came from n-gram counts, a prefix trie and the
system spell checker. It also meant the model tier was never exercised: it was
configured to generate 8 tokens behind a 300ms timeout, which measures at 72ms
against a 40ms debounce, three times over budget and invisible because nobody
had it switched on.

One token, with the KV cache warm, measures at **13.6ms median / 20.6ms p90** on
an M5 — and Qwen3's tokenizer is close to word-level for common English, so one
token is usually a whole word. That is what makes the model affordable per
keystroke, and affordable per keystroke is what makes it worth defaulting on.

### Tests

```bash
swift run TypeAheadTests
```

496 assertions. A plain executable, not XCTest, which ships only with Xcode.

The suite reports three numbers, all on **held-out** writing — `Corpus.train` and
`Corpus.test` are different messages in the same voice:

```
→ 31.5% saved (118 of 375 keystrokes)
→ ExactMatch@1 92.6% at 39.8% coverage
→ log-perplexity 6.912 with boundaries, 7.960 without
```

The savings figure used to read 75% and was measured by replaying the training
text itself, in a corpus of one lowercase line with no punctuation. Coverage is
reported alongside precision because the two trade against each other and neither
means anything alone.

## Architecture

```
KeyTap ──▶ Coordinator ──▶ ContextReader ──▶ SuggestionEngine ──▶ Ranker
              │                                     ▲
              │                                     │  register()
              ├──▶ AcceptanceController      [ SuggestionSource ]
              │      (the only path to text)   identity · corrections · snippets
              │                                 Fusion (n-gram ⊕ model) · lexicon
              ├──▶ Inserter    (the only writer)
              ├──▶ SuggestionOverlay
              └──▶ TypingSignalBus ──▶ [ TypingObserver ]
                                        personal · miner · detector ·
                                        corrector · savings
```

Two extension points carry every feature. Adding one of the seven phases meant
registering a `SuggestionSource` or a `TypingObserver` — `Coordinator` and
`SuggestionEngine` never changed after phase 1.

### Fusion: one distribution, not five arguing

Personal memory and the language model answer the same question — what word comes
next — so they are interpolated rather than pooled and ranked against each other:

```
P(word) = α · P_personal(word) + (1 − α) · P_global(word)      α = 0.4
```

This is the scheme Gmail Smart Compose shipped for the same problem (Chen et al.,
KDD 2019), including the weight. Before it, every tier invented a confidence on
its own scale — a conditional language-model probability, a hand-tuned rank prior,
`0.35 + 0.06n` for snippets — and the ranker compared those numbers directly as
though they were commensurable. `Calibrator` exists because they are not, and it
was treating a category error as a scaling problem.

The union of both vocabularies, not the intersection, is the point. A name only
memory has seen keeps `α` times its probability and can still win; a word only
the model knows carries the sentence where memory has nothing to say; a word both
propose gets both terms and beats either alone.

Measured on held-out writing with Qwen3-0.6B attached:

| | memory only | fused |
|---|---|---|
| log-perplexity | 5.141 | **4.051** |
| coverage | 52.7% | **59.2%** |
| keystrokes saved | 43.9% | **47.8%** |
| ExactMatch@1 | 92.5% | 83.5% |
| latency (p90) | — | **20.5ms** |

Precision falls because coverage rises: the fused model answers in cases where
memory alone declined. Perplexity is the number that says the prediction itself
got better rather than a threshold having moved.

Rule 2 still holds — with no model attached this is exactly the personal model's
own output, unchanged.

### Sentence and paragraph structure

Every separator used to be discarded at the moment a word was committed, so a
space, a comma, a full stop and a Return were one event: "word over". Nothing
downstream could tell a clause break from a sentence end. The consequences were
visible from the outside — suggestions welded to punctuation ("Hi John," +
"thanks " = "Hi John,thanks"), lowercase words at the start of lines, phrases
mined straight through paragraph breaks, and a comma silently switching the
snippet tier off because stored phrases had no punctuation to match against.

`TypingSignal.wordCommitted` now carries a `TextBoundary`, and sentence and
paragraph breaks enter the n-gram as their own tokens, so the model learns what
starts your sentences the same way it learns anything else. Worth 6.912 against
7.960 log-perplexity on held-out text.

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

**Confidence is calibrated against acceptance.** The tiers that remain separate —
snippets, identity, corrections, the lexicon — still invent their own probability
on their own scale, so every origin is rescaled by how often it is actually taken,
relative to the average origin. A redistribution, never an across-the-board cut,
because the savings gate is absolute and deflating everything would silence the
app. It no longer has to referee between the n-gram and the model; those are
interpolated instead.

### The memory, in four tiers

| Tier | Holds | Learned by |
|---|---|---|
| Identity | emails, phone | seeded from your contact card, or after 3 sightings |
| People & terms | names, jargon, projects | automatically |
| Snippets | phrases of 3+ words you repeat | mined after 2 repeats |
| Statistics | n-grams, per-app, with sentence and paragraph markers | every word |

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

496 assertions, `swift run TypeAheadTests`:

- **31.5% keystrokes saved on held-out writing** — still an upper bound, since
  the simulated typist accepts every correct suggestion, but measured on messages
  the model was not trained on. The 74.4% this used to claim was replay of the
  training text.
- **ExactMatch@1 92.6% at 39.8% coverage**, reported together because precision
  and coverage trade against each other
- **log-perplexity 6.912 with sentence boundaries against 7.960 without** — the
  measurement that says the punctuation work improved the prediction rather than
  merely not breaking it
- **fusion arithmetic**: the union of both vocabularies, agreement beating either
  side alone, and an empty model side leaving personal memory untouched
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
- **separators classified rather than discarded**, runs collapsing to their
  strongest member, and carriage return treated as a paragraph break
- **learning and prediction agree token for token** on the sequence, so a trigram
  recorded is a trigram that can be looked up
- suggestions never welded to punctuation; sentence-initial words capitalised
- phrases never mined across a sentence or paragraph break, and a phrase typed
  with a comma still matched after one

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

Latency against a real model *is* now measured, on an M5 with Qwen3-0.6B Q8_0:

| | |
|---|---|
| cold, no prompt cache | 183ms |
| warm, `n_predict=8` (the old setting) | 72ms |
| warm, `n_predict=1` | **13.6ms median / 20.6ms p90** |
| full fused path, end to end | **19.5ms median / 20.5ms p90** |

What is still unmeasured is how this behaves across the app matrix above, and how
the ambient-context read fares in apps whose accessibility trees are unusual —
both need a human at a keyboard.

## Menu bar

- **Suggestions On/Off** — and ⌥⇧Space toggles it from anywhere
- **Start at login** — on by default
- Keystrokes saved, total and this session
- **Model** — catalog, download, hot-swap, "Add model…" for any local GGUF
  (Qwen3-0.6B by default, fetched in the background on first launch)
- **Memory** — review what it knows, export, import, pause learning
- **This app** — never suggest in the app you are currently in

Pausing *learning* and pausing *suggestions* are separate switches: "stop
suggesting but keep learning" and "keep suggesting but stop learning" are both
things you want, and one control could not express either.
