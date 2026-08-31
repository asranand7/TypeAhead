import Cocoa

/// The settings window: everything controllable in one place.
///
/// The menu bar carries the switch and the quick actions, but a menu is a poor
/// place to compare models, manage a blocklist, or read what the app has learned.
/// Those want a window with room and live state.
public final class SettingsWindow: NSObject, NSWindowDelegate {
    private let store: Store
    private let settings: Settings
    private let registry: ModelRegistry
    private let savings: SavingsCounter
    private let coordinator: Coordinator
    private let portability: Portability

    private var window: NSWindow?
    private var reviewWindow: MemoryReviewWindow?
    private var refreshTimer: Timer?

    // Controls that need updating as state changes.
    private var statusLabel = NSTextField(labelWithString: "")
    private var learnedLabel = NSTextField(labelWithString: "")
    private var modelTable = NSTableView()
    private var modelStatusLabel = NSTextField(labelWithString: "")
    private var blockTable = NSTableView()
    private var downloadProgress = NSProgressIndicator()

    private let previewOverlay = SuggestionOverlay()
    private var modelRows: [ModelRegistry.CatalogEntry] = []
    private var customRows: [URL] = []
    private var blockedRows: [String] = []

    public init(store: Store,
                settings: Settings,
                registry: ModelRegistry,
                savings: SavingsCounter,
                coordinator: Coordinator) {
        self.store = store
        self.settings = settings
        self.registry = registry
        self.savings = savings
        self.coordinator = coordinator
        self.portability = Portability(store: store)
        super.init()
    }

    public func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "TypeAhead Settings"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(tabItem("General", generalPane()))
        tabs.addTabViewItem(tabItem("Models", modelsPane()))
        tabs.addTabViewItem(tabItem("Memory", memoryPane()))
        tabs.addTabViewItem(tabItem("Apps", appsPane()))

        window.contentView = tabs
        self.window = window

        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The learned counts change as the user types; a window showing stale
        // numbers is worse than one showing none.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func tabItem(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    // MARK: - General

    private func generalPane() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        var y: CGFloat = 360

        let onOff = NSButton(checkboxWithTitle: "Suggest as I type",
                             target: self, action: #selector(toggleSuggestions))
        onOff.state = coordinator.isEnabled ? .on : .off
        onOff.frame = NSRect(x: 24, y: y, width: 340, height: 20)
        view.addSubview(onOff)
        y -= 26

        view.addSubview(caption("Press ⌥⇧Space anywhere to toggle this.", x: 42, y: y, width: 420))
        y -= 34

        let login = NSButton(checkboxWithTitle: "Start at login",
                             target: self, action: #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        login.frame = NSRect(x: 24, y: y, width: 340, height: 20)
        view.addSubview(login)
        y -= 26

        view.addSubview(caption("Runs in the background with no Dock icon.", x: 42, y: y, width: 420))
        y -= 40

        let inline = NSButton(checkboxWithTitle: "Show suggestions inside the text field",
                              target: self, action: #selector(toggleInline))
        inline.state = settings.inlineEnabled ? .on : .off
        inline.frame = NSRect(x: 24, y: y, width: 380, height: 20)
        view.addSubview(inline)
        y -= 26

        view.addSubview(caption("Off shows a floating pill instead, which never touches "
                                + "your document.", x: 42, y: y, width: 520))
        y -= 40

        let pause = NSButton(checkboxWithTitle: "Pause learning (keep suggesting)",
                             target: self, action: #selector(togglePauseLearning))
        pause.state = settings.isLearningPaused ? .on : .off
        pause.frame = NSRect(x: 24, y: y, width: 380, height: 20)
        view.addSubview(pause)
        y -= 26

        view.addSubview(caption("Separate from the switch above, so you can keep help "
                                + "without recording what you write.", x: 42, y: y, width: 520))
        y -= 46

        statusLabel.frame = NSRect(x: 24, y: y, width: 560, height: 20)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        view.addSubview(statusLabel)
        y -= 24

        learnedLabel.frame = NSRect(x: 24, y: y, width: 560, height: 40)
        learnedLabel.font = .systemFont(ofSize: 11)
        learnedLabel.textColor = .secondaryLabelColor
        learnedLabel.maximumNumberOfLines = 3
        view.addSubview(learnedLabel)
        y -= 48

        // Separates "nothing to suggest" from "suggesting but invisible" — the two
        // failures that look identical from the user's chair.
        let preview = NSButton(title: "Show me what a suggestion looks like",
                               target: self, action: #selector(previewSuggestion))
        preview.frame = NSRect(x: 24, y: y, width: 300, height: 30)
        view.addSubview(preview)

        return view
    }

    // MARK: - Models

    private func modelsPane() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))

        modelStatusLabel.frame = NSRect(x: 24, y: 380, width: 560, height: 18)
        modelStatusLabel.font = .systemFont(ofSize: 11)
        modelStatusLabel.textColor = .secondaryLabelColor
        view.addSubview(modelStatusLabel)

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 92, width: 560, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        modelTable.headerView = nil
        modelTable.usesAlternatingRowBackgroundColors = true
        modelTable.rowHeight = 40
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.width = 540
        modelTable.addTableColumn(column)
        modelTable.dataSource = self
        modelTable.delegate = self
        modelTable.target = self
        modelTable.doubleAction = #selector(activateSelectedModel)
        scroll.documentView = modelTable
        view.addSubview(scroll)

        downloadProgress.frame = NSRect(x: 24, y: 66, width: 560, height: 16)
        downloadProgress.isIndeterminate = false
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 1
        downloadProgress.isHidden = true
        view.addSubview(downloadProgress)

        let use = NSButton(title: "Use selected", target: self,
                           action: #selector(activateSelectedModel))
        use.frame = NSRect(x: 24, y: 24, width: 130, height: 30)
        use.keyEquivalent = "\r"
        view.addSubview(use)

        let add = NSButton(title: "Add model…", target: self, action: #selector(addModel))
        add.frame = NSRect(x: 160, y: 24, width: 120, height: 30)
        view.addSubview(add)

        let install = NSButton(title: "Install llama.cpp…", target: self,
                               action: #selector(explainRuntime))
        install.frame = NSRect(x: 286, y: 24, width: 150, height: 30)
        view.addSubview(install)

        view.addSubview(caption("Swapping models never touches what TypeAhead has "
                                + "learned about you.", x: 446, y: 30, width: 150))
        return view
    }

    // MARK: - Memory

    private func memoryPane() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        var y: CGFloat = 356

        for (title, action, note) in [
            ("Review what it knows…", #selector(showReview),
             "See and delete every word, phrase and fact it has stored."),
            ("Forget my typos…", #selector(forgetTypos),
             "Removes unrecognised words you have not typed often. Names and Hinglish are kept."),
            ("Export memory…", #selector(exportMemory),
             "One file to carry to another Mac. Contains no model data."),
            ("Import memory…", #selector(importMemory),
             "Merges with what this Mac knows — it never overwrites.")
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: 24, y: y, width: 200, height: 30)
            view.addSubview(button)
            view.addSubview(caption(note, x: 236, y: y + 7, width: 350))
            y -= 46
        }

        y -= 10
        let separator = NSBox(frame: NSRect(x: 24, y: y, width: 560, height: 1))
        separator.boxType = .separator
        view.addSubview(separator)
        y -= 30

        let danger = NSButton(title: "Forget everything…", target: self,
                              action: #selector(wipeEverything))
        danger.frame = NSRect(x: 24, y: y, width: 200, height: 30)
        view.addSubview(danger)
        view.addSubview(caption("Deletes the whole store. Cannot be undone.",
                                x: 236, y: y + 7, width: 350))

        return view
    }

    // MARK: - Apps

    private func appsPane() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))

        view.addSubview(caption("TypeAhead ignores these apps completely — it neither "
                                + "suggests nor learns in them. Password fields are always "
                                + "excluded everywhere.", x: 24, y: 372, width: 560))

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 72, width: 560, height: 290))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        blockTable.headerView = nil
        blockTable.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = 540
        blockTable.addTableColumn(column)
        blockTable.dataSource = self
        blockTable.delegate = self
        scroll.documentView = blockTable
        view.addSubview(scroll)

        let add = NSButton(title: "Block an app…", target: self, action: #selector(blockApp))
        add.frame = NSRect(x: 24, y: 24, width: 140, height: 30)
        view.addSubview(add)

        let remove = NSButton(title: "Unblock selected", target: self, action: #selector(unblockApp))
        remove.frame = NSRect(x: 170, y: 24, width: 150, height: 30)
        view.addSubview(remove)

        return view
    }

    // MARK: - Refresh

    private func refresh() {
        let words = (try? store.allVocab().count) ?? 0
        let usable = (try? store.allVocab().filter {
            WordHygiene.isOfferable(kind: $0.kind, count: $0.count)
        }.count) ?? 0
        let phrases = (try? store.allSnippets().filter {
            $0.count >= SnippetMiner.promotionThreshold
        }.count) ?? 0

        statusLabel.stringValue = coordinator.isEnabled
            ? "Watching — \(savings.totalKeystrokesSaved) keystrokes saved so far"
            : "Suggestions are off"

        // The honest reason the app looks idle early on: it has not seen enough
        // yet. Saying so beats letting the user conclude it is broken.
        if usable == 0 {
            learnedLabel.stringValue = "Knows \(words) words, but none often enough to suggest yet. "
                + "A word needs 2 sightings, an unfamiliar one needs \(WordHygiene.unknownWordThreshold), "
                + "and a phrase needs \(SnippetMiner.promotionThreshold) repeats."
        } else {
            learnedLabel.stringValue = "Knows \(words) words — \(usable) ready to suggest, "
                + "\(phrases) phrases learned."
        }

        modelRows = ModelRegistry.catalog
        let known = Set(ModelRegistry.catalog.map(\.file))
        customRows = registry.installedModelPaths().filter { !known.contains($0.lastPathComponent) }
        modelStatusLabel.stringValue = GGUFModel.isRuntimeAvailable
            ? "llama.cpp found. A model adds general fluency; your memory works without one."
            : "llama.cpp is not installed, so models are unavailable. TypeAhead works without one."
        modelTable.reloadData()

        blockedRows = Array(settings.blockedApps).sorted()
        blockTable.reloadData()
    }

    private func caption(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.frame = NSRect(x: x, y: y - 14, width: width, height: 32)
        field.isSelectable = false
        return field
    }

    // MARK: - Actions

    @objc private func toggleSuggestions() { coordinator.toggle(); refresh() }
    @objc private func togglePauseLearning() { settings.isLearningPaused.toggle(); refresh() }
    @objc private func toggleInline() { settings.inlineEnabled.toggle(); refresh() }

    @objc private func toggleLaunchAtLogin() {
        let wanted = !LaunchAtLogin.isEnabled
        // Remembered so the self-healing path never argues with a deliberate no.
        LaunchAtLogin.noteUserChoice(wanted)
        if !LaunchAtLogin.setEnabled(wanted) {
            MemoryMenu.inform("Login item is managed in System Settings",
                              "Open System Settings › General › Login Items.")
        }
        refresh()
    }

    /// Displays a fake suggestion so the overlay can be seen on demand.
    ///
    /// A suggestion appears as a floating pill beside the caret, not as text
    /// inside the field — no app can draw inside another app's text view. Showing
    /// one on request is the only way to make that concrete.
    @objc private func previewSuggestion() {
        guard let window else { return }
        let anchor = CGRect(x: window.frame.midX - 120,
                            y: window.frame.minY - 30,
                            width: 2,
                            height: 18)
        previewOverlay.show(text: "regards, Anand", at: anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.previewOverlay.hide()
        }
    }

    @objc private func activateSelectedModel() {
        let row = modelTable.selectedRow
        guard row >= 0 else { return }

        if row < modelRows.count {
            let entry = modelRows[row]
            loadModel(entry)
            return
        }

        let custom = customRows[row - modelRows.count]
        _ = registry.activate(path: custom,
                              entryID: custom.deletingPathExtension().lastPathComponent)
        refresh()
    }

    /// Loads a catalog model, fetching it through llama.cpp if this is its first
    /// use. Runs off the main thread: the first run of a model downloads hundreds
    /// of megabytes, and blocking the main thread would freeze the whole app.
    private func loadModel(_ entry: ModelRegistry.CatalogEntry) {
        if entry.id != "none", !registry.isInstalled(entry) {
            let confirm = NSAlert()
            confirm.messageText = "Download \(entry.displayName)?"
            confirm.informativeText = """
                About \(ModelMenu.size(entry.approximateBytes)) will be downloaded by \
                llama.cpp from \(entry.repo) and cached for future use.

                \(entry.note)

                You can keep typing while it downloads — TypeAhead runs on memory \
                in the meantime, and your memory is unaffected either way.
                """
            confirm.addButton(withTitle: "Download")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        downloadProgress.isHidden = false
        downloadProgress.isIndeterminate = true
        downloadProgress.startAnimation(nil)
        modelStatusLabel.stringValue = "Loading \(entry.displayName)… this can take a while on first use."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.registry.activate(entry)
            let error = self.registry.lastError
            DispatchQueue.main.async {
                self.downloadProgress.stopAnimation(nil)
                self.downloadProgress.isIndeterminate = false
                self.downloadProgress.isHidden = true
                if !ok, entry.id != "none" {
                    // Surfaced, not swallowed. A silent fall back to memory-only
                    // is what let a 29-byte error page sit in the list looking
                    // like an installed model.
                    MemoryMenu.inform("Could not load \(entry.displayName)",
                                      (error ?? "Unknown error.")
                                      + "\n\nTypeAhead is still running on memory alone, which works.")
                }
                self.refresh()
            }
        }
    }

    @objc private func addModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a GGUF model file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if try !registry.addLocalModel(at: url) {
                MemoryMenu.inform("Could not load that model",
                                  "It may not be a valid GGUF, or llama-server failed to start.")
            }
            refresh()
        } catch {
            MemoryMenu.inform("Could not add that model", "\(error)")
        }
    }

    @objc private func explainRuntime() {
        MemoryMenu.inform("Models need llama.cpp", """
            Install it with:
                brew install llama.cpp

            Then reopen this window and pick a model.

            Optional: the half that learns your writing needs no model at all.
            """)
    }

    @objc private func showReview() {
        let review = reviewWindow ?? MemoryReviewWindow(store: store)
        reviewWindow = review
        review.present()
    }

    @objc private func forgetTypos() {
        let removed = (try? store.forgetUnverified(
            seenFewerThan: WordHygiene.unknownWordThreshold)) ?? 0
        MemoryMenu.inform("Forgot \(removed) words", "Your real vocabulary is untouched.")
        refresh()
    }

    @objc private func exportMemory() {
        guard let options = ExportReviewSheet(store: store).runModal() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "typeahead-memory-\(MemoryMenu.dateStamp()).\(Portability.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try portability.export(to: url, options: options)
            MemoryMenu.inform("Memory exported",
                              "\(manifest.wordCount) words, \(manifest.snippetCount) phrases, "
                              + "\(manifest.identityCount) identity facts.")
        } catch {
            MemoryMenu.inform("Export failed", "\(error)")
        }
    }

    @objc private func importMemory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try portability.importMemory(from: url)
            MemoryMenu.inform("Memory imported",
                              "\(summary.wordsAdded) new words, \(summary.wordsMerged) merged, "
                              + "\(summary.ngramsMerged) statistics.")
            refresh()
        } catch {
            MemoryMenu.inform("Import failed", "\(error)")
        }
    }

    @objc private func wipeEverything() {
        let alert = NSAlert()
        alert.messageText = "Forget everything TypeAhead has learned?"
        alert.informativeText = "Every word, phrase, correction and identity fact is deleted. "
            + "This cannot be undone. Export first if you want a copy."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Forget everything")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.wipe()
        refresh()
    }

    @objc private func blockApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Choose an app TypeAhead should ignore"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        settings.block(id)
        refresh()
    }

    @objc private func unblockApp() {
        let row = blockTable.selectedRow
        guard row >= 0, blockedRows.indices.contains(row) else { return }
        settings.unblock(blockedRows[row])
        refresh()
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window = nil
    }
}

extension SettingsWindow: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === modelTable ? modelRows.count + customRows.count : blockedRows.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        if tableView === blockTable {
            guard blockedRows.indices.contains(row) else { return nil }
            return NSTextField(labelWithString: blockedRows[row])
        }

        let title: String
        let subtitle: String
        let isActive: Bool

        if row < modelRows.count {
            let entry = modelRows[row]
            title = entry.displayName
            isActive = registry.activeEntryID == entry.id
            if entry.id == "none" {
                subtitle = entry.note
            } else if registry.isInstalled(entry) {
                subtitle = "Cached · \(entry.repo)"
            } else {
                subtitle = "Downloads \(ModelMenu.size(entry.approximateBytes)) on first use · \(entry.repo)"
            }
        } else {
            let custom = customRows[row - modelRows.count]
            title = custom.deletingPathExtension().lastPathComponent
            subtitle = "Added by you · \(custom.path)"
            isActive = registry.activeEntryID == title
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 40))
        let name = NSTextField(labelWithString: (isActive ? "● " : "   ") + title)
        name.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        name.frame = NSRect(x: 4, y: 20, width: 520, height: 17)
        container.addSubview(name)

        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.frame = NSRect(x: 20, y: 4, width: 510, height: 14)
        container.addSubview(detail)

        return container
    }
}
