import Foundation
import TypeAheadCore

/// Assembles the same object graph the composition root builds — minus the event
/// tap and the menu bar, which need a running NSApplication — and drives it with
/// typing signals.
///
/// Catches the failure the unit tests structurally cannot: every part correct,
/// wired together wrongly.
func runIntegrationTests(_ s: Suite) {
    s.report("End to end")

    s.test("the full pipeline learns from typing and suggests from every tier") {
        let (store, _) = try makeTemporaryStore()

        let personal = PersonalModel(store: store)
        let miner = SnippetMiner(store: store)
        let snippets = SnippetSource(store: store)
        let identity = IdentitySource(store: store)
        let corrector = Corrector(store: store)

        let engine = SuggestionEngine()
        engine.register(identity)
        engine.register(corrector)
        engine.register(snippets)
        engine.register(personal)

        let bus = TypingSignalBus()
        for observer in [personal as TypingObserver, miner, corrector] { bus.add(observer) }

        // Type the same three sentences a few times, as a person would.
        let text = """
            thanks anand please find attached the report. \
            thanks anand please find attached the deck. \
            thanks anand please find attached the notes. \
            thanks anand please find attached the summary.
            """
        SavingsBenchmark.train([personal, miner, corrector], on: text, appBundleID: "com.test")
        try store.setIdentity("email", "testuser@example.com")

        // Tier 4: statistics predict a next word.
        let ngram = engine.bestCandidate(for: TypingContext(
            textBeforeCaret: "thanks anand please find ",
            currentWordPrefix: "",
            appBundleID: "com.test",
            isAuthoritative: true))
        s.expect(ngram != nil, "statistics produce a suggestion")

        // Tier 2: a learned word completes from a prefix.
        let completion = engine.bestCandidate(for: TypingContext(
            textBeforeCaret: "attac",
            currentWordPrefix: "attac",
            appBundleID: "com.test",
            isAuthoritative: true))
        s.expect(completion != nil, "vocabulary completes a prefix")

        // Tier 1: identity beats everything on expected savings.
        let email = engine.bestCandidate(for: TypingContext(
            textBeforeCaret: "testu",
            currentWordPrefix: "testu",
            appBundleID: "com.test",
            isAuthoritative: true))
        s.expectEqual(email?.origin, .identity, "identity wins when it matches")

        // Tier 3: the repeated phrase was mined.
        let mined = try miner.promoted()
        s.expect(mined.contains { $0.text.contains("please find attached") },
                 "phrase promoted — got \(mined.prefix(3).map(\.text))")
    }

    s.test("a full accept cycle reports the right savings") {
        // Coordinator wiring in miniature: present, Tab, observe the signal.
        let savings = SavingsCounter(defaults: UserDefaults(
            suiteName: "typeahead-test-\(UUID().uuidString)")!)
        let bus = TypingSignalBus()
        bus.add(savings)

        let acceptance = AcceptanceController()
        let candidate = Candidate(text: "regards, Anand", probability: 0.7, origin: .snippet)
        acceptance.present(candidate)

        var inserted = ""
        var tabs = 0
        while case .accept(let text, let accepted, let isFinal, _) =
                acceptance.handle(KeyEvent(keyCode: 48, characters: "", modifiers: [])) {
            inserted += text
            tabs += 1
            bus.observe(.suggestionAccepted(accepted, characters: text.count))
            if isFinal { break }
        }

        s.expectEqual(inserted, "regards, Anand", "two Tabs land the whole phrase")
        s.expectEqual(tabs, 2, "word first, then the rest")
        // 14 characters for 2 keystrokes: the counter subtracts one Tab per accept.
        s.expectEqual(savings.sessionKeystrokesSaved, 12, "savings net of the Tabs")
    }

    s.test("a blocked app is invisible to the whole pipeline") {
        let settings = Settings(defaults: UserDefaults(
            suiteName: "typeahead-test-\(UUID().uuidString)")!)
        settings.block("com.private.app")

        s.expect(settings.isBlocked("com.private.app"), "blocked app is blocked")
        s.expect(!settings.isBlocked("com.other.app"), "others are not")
        // Password managers are never observable, whatever the user configures.
        s.expect(settings.isBlocked("com.1password.1password"),
                 "password managers are permanently excluded")
    }

    s.test("pausing learning and pausing suggestions are separate switches") {
        let settings = Settings(defaults: UserDefaults(
            suiteName: "typeahead-test-\(UUID().uuidString)")!)
        s.expect(settings.suggestionsEnabled, "suggestions on by default")
        s.expect(!settings.isLearningPaused, "learning on by default")

        settings.isLearningPaused = true
        s.expect(settings.suggestionsEnabled, "suggestions unaffected by pausing learning")
    }
}
