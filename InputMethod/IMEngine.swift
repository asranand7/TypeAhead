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
    private let fusion: Fusion

    /// The menu-bar app's model, if it happens to be running.
    ///
    /// Attached, never spawned. The input method is a second front-end onto the
    /// same brain, not a second product, and a second llama-server would mean a
    /// second 640MB of weights fighting the first for the same port. When nothing
    /// is there this stays nil and `Fusion` degrades to personal memory — which
    /// is what the input method did for its whole life anyway.
    private var attachedModel: GGUFModel?
    private var lastAttachAttempt: Date?
    private let attachLock = NSLock()

    /// How often to look again for a model that was not there last time. Long
    /// enough that a permanently model-less setup pays almost nothing, short
    /// enough that starting the menu-bar app is noticed within a sentence or two.
    private static let attachRetryInterval: TimeInterval = 30

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

        fusion = Fusion(personal: personal, model: { IMEngine.shared.model() })

        engine.register(identity)
        engine.register(corrector)
        engine.register(snippets)
        engine.register(fusion)

        signals.add(personal)
        signals.add(miner)
        signals.add(corrector)
        signals.add(savings)
    }

    /// A running model to fuse against, or nil.
    ///
    /// Re-probed on a throttle rather than held, so an input method that started
    /// before the menu-bar app still picks the model up, and one whose model has
    /// gone away stops asking a dead port on every keystroke.
    private func model() -> GGUFModel? {
        attachLock.lock()
        defer { attachLock.unlock() }

        if let attachedModel, attachedModel.isRunning { return attachedModel }

        let due = lastAttachAttempt.map {
            Date().timeIntervalSince($0) >= IMEngine.attachRetryInterval
        } ?? true
        guard due else { return nil }
        lastAttachAttempt = Date()

        let candidate = GGUFModel(name: "attached", source: .local(path: ""))
        attachedModel = candidate.attach() ? candidate : nil
        return attachedModel
    }

    func observe(_ signal: TypingSignal) {
        switch signal {
        case .typed, .wordCommitted, .backspaced, .boundaryCrossed:
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
