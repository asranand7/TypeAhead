import Foundation
import TypeAheadCore

/// Answers "is it suggesting anything?" against the *real* store, without needing
/// the app running or a text field in front of you.
///
/// Exists because the honest failure modes are hard to tell apart from outside:
/// nothing learned yet, learned but below the confidence gate, or suggesting fine
/// but the overlay is not visible. This separates them.

let arguments = Array(CommandLine.arguments.dropFirst())

let storePath = (try? Store.defaultPath()) ?? ""
guard FileManager.default.fileExists(atPath: storePath) else {
    print("No memory store at \(storePath) — the app has not run yet.")
    exit(1)
}

let store = try Store(path: storePath)
let personal = PersonalModel(store: store)
let snippets = SnippetSource(store: store)
let identity = IdentitySource(store: store)
let corrector = Corrector(store: store)
let lexicon = SystemLexicon()

let engine = SuggestionEngine()
engine.register(identity)
engine.register(corrector)
engine.register(snippets)
engine.register(personal)
engine.register(lexicon)

func probe(_ text: String) {
    let prefix = ContextReader.trailingWord(of: text)
    let context = TypingContext(textBeforeCaret: text,
                                currentWordPrefix: prefix,
                                appBundleID: nil,
                                isAuthoritative: true)
    let all = engine.candidates(for: context)

    print("  \"\(text)\"")
    if all.isEmpty {
        print("      (nothing clears the gate)")
    }
    for candidate in all.prefix(4) {
        let saved = Ranker.keystrokesSaved(candidate)
        print(String(format: "      → %-24@ %-11@ p=%.2f saves %d  score %.2f",
                     "\"\(candidate.text)\"" as NSString,
                     candidate.origin.rawValue as NSString,
                     candidate.probability,
                     saved,
                     Ranker.expectedSavings(candidate)))
    }
}

// If a llama-server is already up, exercise the real model path and report what
// it returns and how long it takes. This is the only honest answer to "is the
// model actually being used".
let probeModel = GGUFModel(name: "attached", source: .local(path: ""), port: 8177)
if probeModel.attach() {
    print("Model: llama-server responding on 127.0.0.1:8177")
    for text in ["Please find attached the ", "Thanks for your ", "kaise ho "] {
        let ctx = TypingContext(textBeforeCaret: text, currentWordPrefix: "",
                                appBundleID: nil, isAuthoritative: true)
        let start = DispatchTime.now()
        let candidates = probeModel.suggest(ctx)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let shown = candidates.isEmpty
            ? "(nothing)"
            : candidates.map { "\"\($0.text)\" p=\($0.probability)" }.joined(separator: ", ")
        print(String(format: "  %-28@ → %@  [%.0fms]", "\"\(text)\"" as NSString, shown as NSString, ms))
    }
    engine.register(probeModel)
    print("")
} else {
    print("Model: no llama-server on 127.0.0.1:8177 — memory only")
    print("")
}

// Explicit probes win; otherwise derive them from what has actually been learned.
if !arguments.isEmpty {
    print("Probing your store:")
    for argument in arguments { probe(argument) }
    exit(0)
}

let vocabulary = try store.allVocab()
let ready = vocabulary.filter { $0.count >= 2 && $0.word.count >= 4 }

print("TypeAhead doctor")
print("────────────────")
print("  store        \(storePath)")
print("  vocabulary   \(vocabulary.count) words, \(ready.count) usable for completion")
print("  statistics   \(try store.database.query("SELECT COALESCE(SUM(count),0) AS t FROM ngram").first?.int("t") ?? 0) observations")
print("  phrases      \(try store.allSnippets().filter { $0.count >= SnippetMiner.promotionThreshold }.count) promoted")
print("  identity     \(try store.identityFacts().count) confirmed facts")
print("  feedback     \(try store.database.query("SELECT COALESCE(SUM(shown),0) AS s FROM feedback").first?.int("s") ?? 0) shown, \(try store.database.query("SELECT COALESCE(SUM(accepted),0) AS a FROM feedback").first?.int("a") ?? 0) accepted")
print("")

// A completion has to be worth more than the Tab that takes it, so a word needs
// enough letters left after the prefix to clear the gate. This is the single
// most common reason a store that "knows" a word still says nothing.
print("Words it could actually complete:")
if ready.isEmpty {
    print("  none yet — a word must be seen at least twice AND be long enough")
    print("  that finishing it beats the one keystroke Tab costs.")
    print("")
    print("  Type a distinctive long word twice, each followed by a space:")
    print("      accessibility accessibility ")
    print("  then start typing \"access\" and the rest should appear.")
} else {
    for entry in ready.prefix(10) {
        let cut = min(2, entry.word.count - 1)
        let prefix = String(entry.word.prefix(cut))
        print("  \"\(prefix)…\" → \(entry.word)  (seen \(entry.count)×)")
    }
}

print("")
print("Live probes:")
for entry in ready.prefix(5) {
    probe(String(entry.word.prefix(max(2, entry.word.count - 2))))
}
if ready.isEmpty {
    probe("the")
    probe("typ")
}
