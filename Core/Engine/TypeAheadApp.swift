import Cocoa

/// Composition root: the one place that decides which parts make up the app.
///
/// Every phase of the build attaches here and nowhere else — sources register
/// with the engine, learners register with the signal bus, menus register with
/// the menu bar. Nothing in `Coordinator` or `SuggestionEngine` had to change to
/// accommodate any of them, which was the point of the two extension points.
public final class TypeAheadApp: NSObject, NSApplicationDelegate {
    private var engine: SuggestionEngine!
    private let settings = Settings()
    private let savings = SavingsCounter()

    private var store: Store!
    private var calibrator: Calibrator!
    private var personal: PersonalModel!
    private var fusion: Fusion!
    private var snippetMiner: SnippetMiner!
    private var snippetSource: SnippetSource!
    private var identityDetector: IdentityDetector!
    private var identitySource: IdentitySource!
    private var corrector: Corrector!
    private var lexicon: SystemLexicon!
    private var registry: ModelRegistry!

    private var coordinator: Coordinator!
    private var menuBar: MenuBarController!
    private var hotKey: HotKey!
    private var settingsWindow: SettingsWindow!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store(path: try Store.defaultPath())
        } catch {
            presentFatal("Could not open the memory store", "\(error)")
            return
        }

        // Both need the store, so the engine cannot be built before it opens.
        calibrator = Calibrator(store: store)
        engine = SuggestionEngine(calibrator: calibrator)

        buildPredictors()
        buildCoordinator()
        buildMenuBar()
        buildHotKey()

        registry.restoreActive()
        rebuildSources()

        // Sweep away mining candidates that never repeated. On launch rather than
        // on a timer: it is a bulk delete, it must not land in the middle of the
        // keystroke path, and a store only degrades over days.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let store = self?.store else { return }
            if let removed = try? store.pruneUnrepeatedSnippets(), removed > 0 {
                NSLog("TypeAhead: pruned \(removed) phrases that were seen once and never again")
            }
        }

        // On by default, in the background: a typing aid you have to launch is one
        // you stop using.
        LaunchAtLogin.configureOnFirstRun()

        // The Mac already knows the user's own email and phone. Recorded
        // unconfirmed, so they arrive through the same review prompt a detected
        // fact would — the point is to skip the three repetitions, not the
        // consent. Silent when Contacts access has never been granted.
        seedIdentityFromContacts()

        if settings.suggestionsEnabled, !coordinator.enable() {
            menuBar.presentPermissionPrompt()
        }
    }

    /// Offers the me-card facts for confirmation, one prompt each.
    private func seedIdentityFromContacts() {
        ContactSeed.seed(into: store) { [weak self] facts in
            DispatchQueue.main.async {
                for (kind, value) in facts {
                    self?.askAboutIdentity(kind: kind, value: value)
                }
            }
        }
    }

    // MARK: - Assembly

    private func buildPredictors() {
        personal = PersonalModel(store: store)
        snippetMiner = SnippetMiner(store: store)
        snippetSource = SnippetSource(store: store)
        identityDetector = IdentityDetector(store: store)
        identitySource = IdentitySource(store: store)
        corrector = Corrector(store: store)
        lexicon = SystemLexicon()

        identityDetector.onCandidate = { [weak self] kind, value in
            DispatchQueue.main.async { self?.askAboutIdentity(kind: kind, value: value) }
        }

        registry = ModelRegistry(engine: engine) { [weak self] in
            self?.rebuildSources()
        }

        // The model is read through the registry on every call rather than
        // captured, so a hot swap takes effect on the next keystroke and a
        // stopped model is never held alive by this reference. Rule 2: the model
        // is a commodity, and nothing here outlives one.
        fusion = Fusion(personal: personal) { [weak self] in self?.registry.active }
    }

    /// Rebuilt wholesale on every model swap. Cheap, and it keeps registration
    /// order in exactly one place instead of spread across the swap paths.
    private func rebuildSources() {
        engine.removeAllSources()
        engine.register(identitySource)   // longest, most certain wins
        engine.register(corrector)
        engine.register(snippetSource)
        // One source, not two. Personal memory and the language model answer the
        // same question — what word comes next — so they are interpolated into a
        // single distribution rather than pooled and sorted against each other on
        // scales that were never comparable. With no model attached this is
        // exactly the personal model's own output.
        engine.register(fusion)
        // General English, so the app is useful before it has learned anything.
        // Registered last of the personal sources and scored lower, so it fades
        // behind personal memory rather than competing with it.
        engine.register(lexicon)
    }

    private func buildCoordinator() {
        coordinator = Coordinator(engine: engine, settings: settings)
        // Order here is presentation only; each observer is independent.
        coordinator.addObserver(personal)
        coordinator.addObserver(snippetMiner)
        coordinator.addObserver(identityDetector)
        coordinator.addObserver(corrector)
        coordinator.addObserver(savings)

        coordinator.onStateChange = { [weak self] enabled in
            self?.settings.suggestionsEnabled = enabled
        }
    }

    private func buildMenuBar() {
        settingsWindow = SettingsWindow(store: store,
                                        settings: settings,
                                        registry: registry,
                                        savings: savings,
                                        coordinator: coordinator)
        menuBar = MenuBarController(coordinator: coordinator, savings: savings)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.present() }
        menuBar.add(ModelMenu(registry: registry) { [weak self] in
            self?.menuBar.refresh()
        })
        menuBar.add(MemoryMenu(store: store, settings: settings))
        menuBar.add(AppsMenu(settings: settings))
    }

    private func buildHotKey() {
        hotKey = HotKey { [weak self] in
            self?.coordinator.toggle()
        }
        hotKey.register()
    }

    // MARK: - Identity prompts

    /// Detection never stores silently — this is the ask. Until it is answered the
    /// fact is unconfirmed: invisible to suggestions and excluded from export.
    private func askAboutIdentity(kind: IdentityDetector.Kind, value: String) {
        let alert = NSAlert()
        alert.messageText = "Remember this \(kind.rawValue)?"
        alert.informativeText = """
            You have typed \(value) a few times.

            If TypeAhead remembers it, typing the first few characters will offer \
            the rest — which is a lot of keystrokes for something this long.

            It is stored only on this Mac, and you can remove it any time from \
            Review what it knows.
            """
        alert.addButton(withTitle: "Remember")
        alert.addButton(withTitle: "No")

        if alert.runModal() == .alertFirstButtonReturn {
            try? identityDetector.confirm(kind: kind, value: value)
        } else {
            try? identityDetector.reject(kind: kind, value: value)
        }
    }

    private func presentFatal(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator?.disable()
        registry?.active?.stop()
        hotKey?.unregister()
    }
}

/// Per-app control: block the app you are in right now.
///
/// Blocking by name from a list of everything installed would be a worse
/// interaction — you notice you want this *while typing in the app*, so the menu
/// offers the frontmost one.
final class AppsMenu: NSObject, MenuContributor {
    let menuTitle = "This app"

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    func makeMenuItems() -> [NSMenuItem] {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return []
        }
        let name = app.localizedName ?? bundleID
        let blocked = settings.isBlocked(bundleID)

        let toggle = NSMenuItem(
            title: blocked ? "Enable in \(name)" : "Never suggest in \(name)",
            action: #selector(toggleBlocked(_:)),
            keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = bundleID
        // Password managers are permanently excluded and not the user's to change.
        toggle.isEnabled = !Settings.alwaysBlocked.contains(bundleID)

        var items = [toggle]
        let blockedCount = settings.blockedApps.count
        if blockedCount > 0 {
            let summary = NSMenuItem(title: "\(blockedCount) app\(blockedCount == 1 ? "" : "s") blocked",
                                     action: nil, keyEquivalent: "")
            summary.isEnabled = false
            items.append(summary)
        }
        return items
    }

    @objc private func toggleBlocked(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if settings.isBlocked(bundleID) {
            settings.unblock(bundleID)
        } else {
            settings.block(bundleID)
        }
    }
}
