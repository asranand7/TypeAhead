import Cocoa
import TypeAheadCore

/// The shared brain for the input method.
///
/// `IMKInputController` is instantiated per client application, so the store and
/// the engine cannot live on the controller — they would be duplicated per app
/// and each copy would learn only a fraction of what is typed. One singleton,
/// many controllers.
///
/// Everything here is the *same* engine the menu-bar app uses. The input method
/// is a new front-end, not a new product: same memory, same ranking, same
/// corrections, same export file.
final class IMEngine {
    static let shared = IMEngine()

    let store: Store
    let engine = SuggestionEngine()
    let settings = Settings()
    let savings = SavingsCounter()

    private let signals = TypingSignalBus()
    private let personal: PersonalModel
    private let miner: SnippetMiner
    private let corrector: Corrector
    private let identity: IdentitySource
    private let snippets: SnippetSource

    private init() {
        // Falling back to a temporary store keeps the input method alive if the
        // real one cannot be opened. An IME that throws on launch takes the user's
        // ability to type with it.
        let path = (try? Store.defaultPath())
            ?? NSTemporaryDirectory() + "typeahead-fallback.sqlite"
        store = (try? Store(path: path))
            ?? (try! Store(path: NSTemporaryDirectory() + "typeahead-fallback.sqlite"))

        personal = PersonalModel(store: store)
        miner = SnippetMiner(store: store)
        corrector = Corrector(store: store)
        identity = IdentitySource(store: store)
        snippets = SnippetSource(store: store)

        engine.register(identity)
        engine.register(corrector)
        engine.register(snippets)
        engine.register(personal)

        signals.add(personal)
        signals.add(miner)
        signals.add(corrector)
        signals.add(savings)
    }

    func observe(_ signal: TypingSignal) {
        switch signal {
        case .typed, .wordCommitted, .backspaced:
            guard !settings.isLearningPaused else { return }
        default:
            break
        }
        signals.observe(signal)
    }

    func bestSuggestion(for context: TypingContext) -> Candidate? {
        guard !settings.isBlocked(context.appBundleID) else { return nil }
        return engine.bestCandidate(for: context)
    }
}
