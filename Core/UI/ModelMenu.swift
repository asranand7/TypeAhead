import Cocoa

/// The model picker.
///
/// Rule 2 made visible: a list of interchangeable parts, one of which is "none".
/// Switching costs nothing and changes nothing about what the app knows.
public final class ModelMenu: NSObject, MenuContributor {
    public let menuTitle = "Model"

    private let registry: ModelRegistry
    private var onChange: () -> Void

    public init(registry: ModelRegistry, onChange: @escaping () -> Void) {
        self.registry = registry
        self.onChange = onChange
    }

    public func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if !GGUFModel.isRuntimeAvailable {
            let missing = NSMenuItem(title: "llama.cpp not installed", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            items.append(missing)

            let install = NSMenuItem(title: "How to enable models…",
                                     action: #selector(explainRuntime),
                                     keyEquivalent: "")
            install.target = self
            items.append(install)
            return items
        }

        for entry in ModelRegistry.catalog {
            let installed = registry.isInstalled(entry)
            let title: String
            if entry.id == "none" || installed {
                title = entry.displayName
            } else {
                title = "\(entry.displayName) — downloads \(ModelMenu.size(entry.approximateBytes))"
            }

            let item = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = registry.activeEntryID == entry.id ? .on : .off
            items.append(item)
        }

        // Anything the user dropped in themselves.
        let known = Set(ModelRegistry.catalog.map(\.file))
        for path in registry.installedModelPaths() where !known.contains(path.lastPathComponent) {
            let id = path.deletingPathExtension().lastPathComponent
            let item = NSMenuItem(title: id, action: #selector(selectCustom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = registry.activeEntryID == id ? .on : .off
            items.append(item)
        }

        let add = NSMenuItem(title: "Add model…", action: #selector(addModel), keyEquivalent: "")
        add.target = self
        items.append(add)

        return items
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = ModelRegistry.catalog.first(where: { $0.id == id }) else { return }

        activate(entry)
    }

    @objc private func selectCustom(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? URL else { return }
        let id = path.deletingPathExtension().lastPathComponent
        if !registry.activate(path: path, entryID: id) {
            MemoryMenu.inform("Could not load that model",
                              "The file may not be a valid GGUF, or llama-server failed to start. " +
                              "TypeAhead is still running on memory alone.")
        }
        onChange()
    }

    /// Loading can take minutes on a model's first use, so it never runs on the
    /// main thread. Full control lives in Settings; this is the quick path.
    private func activate(_ entry: ModelRegistry.CatalogEntry) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.registry.activate(entry)
            let error = self.registry.lastError
            DispatchQueue.main.async {
                if !ok, entry.id != "none" {
                    MemoryMenu.inform("Could not load \(entry.displayName)",
                                      (error ?? "Unknown error.")
                                      + "\n\nTypeAhead is still running on memory alone.")
                }
                self.onChange()
            }
        }
    }

    @objc private func addModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GGUF model file"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            if try !registry.addLocalModel(at: url) {
                MemoryMenu.inform("Could not load that model",
                                  "The file may not be a valid GGUF, or llama-server failed to start.")
            }
            onChange()
        } catch {
            MemoryMenu.inform("Could not add that model", "\(error)")
        }
    }

    @objc private func explainRuntime() {
        MemoryMenu.inform(
            "Models need llama.cpp",
            """
            TypeAhead runs GGUF models through llama-server, which is not installed.

            Install it with:
                brew install llama.cpp

            Then reopen this menu and pick a model.

            This is entirely optional. TypeAhead works on memory alone — that is \
            the half that learns your writing, and it needs no model at all.
            """)
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
