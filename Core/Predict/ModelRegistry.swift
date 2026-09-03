import Foundation

/// The model picker: catalog, download, hot-swap, and "add your own".
///
/// Rule 2 in operational form. Swapping a model unloads one process and loads
/// another; the memory store is not consulted, not migrated, and not touched.
/// Selecting "none" is a first-class choice, not a failure state.
public final class ModelRegistry {
    public struct CatalogEntry: Equatable {
        public let id: String
        public let displayName: String
        /// Hugging Face repo, e.g. "ggml-org/Qwen3-0.6B-GGUF". Empty for the
        /// memory-only entry.
        public let repo: String
        /// Exact filename within the repo. Named explicitly rather than inferred
        /// from a quant label, because repos do not all carry the same quants —
        /// ggml-org's Qwen3-0.6B has Q4_0 and Q8_0 but no Q4_K_M, and guessing
        /// produces a 404 that used to be saved as a model file.
        public let file: String
        public let approximateBytes: Int64
        public let note: String

        /// The memory-only option. Not an absence of a model — a valid choice the
        /// app is designed to run in.
        public static let none = CatalogEntry(
            id: "none",
            displayName: "No model (memory only)",
            repo: "",
            file: "",
            approximateBytes: 0,
            note: "Fully functional; less general fluency")
    }

    /// Curated defaults. Small enough to answer inside a keystroke, multilingual
    /// enough to cover more than English.
    /// Every repo and filename here was verified to exist and be publicly
    /// downloadable. The previous catalog was written from memory and every entry
    /// 401'd or 404'd.
    public static let catalog: [CatalogEntry] = [
        CatalogEntry(
            id: "qwen3-0.6b",
            displayName: "Qwen3 0.6B (Q8_0)",
            repo: "ggml-org/Qwen3-0.6B-GGUF",
            file: "Qwen3-0.6B-Q8_0.gguf",
            approximateBytes: 640_000_000,
            note: "Default — smallest and fastest, broad language coverage"),
        CatalogEntry(
            id: "gemma3-1b",
            displayName: "Gemma 3 1B (Q4_K_M)",
            repo: "ggml-org/gemma-3-1b-it-GGUF",
            file: "gemma-3-1b-it-Q4_K_M.gguf",
            approximateBytes: 800_000_000,
            note: "Strong multilingual alternative"),
        CatalogEntry(
            id: "qwen3-1.7b",
            displayName: "Qwen3 1.7B (Q4_K_M)",
            repo: "lmstudio-community/Qwen3-1.7B-GGUF",
            file: "Qwen3-1.7B-Q4_K_M.gguf",
            approximateBytes: 1_100_000_000,
            note: "Better quality; only fires when you pause"),
        .none
    ]

    /// What a fresh install runs.
    ///
    /// Not "none". Memory-only was the default for as long as the model tier
    /// existed, which meant the shipping app had no language model in it at all —
    /// every suggestion came from n-gram counts, a prefix trie and the system
    /// spell checker. That is a 1990s recommender, and it is what "it just
    /// recommends stuff" was describing.
    ///
    /// The smallest catalog entry is the right default because it is the one that
    /// fits the keystroke budget: measured on an M5, Qwen3-0.6B answers a
    /// one-word completion in ~23ms against a 40ms debounce, with the prompt
    /// cache warm. Memory-only remains a first-class choice, and remains what the
    /// app falls back to whenever the model cannot be loaded.
    public static let defaultEntryID = "qwen3-0.6b"

    public private(set) var active: GGUFModel?
    public private(set) var activeEntryID: String
    /// Why the last activation failed. Surfaced to the user rather than letting a
    /// silent fallback to memory-only look like success.
    public private(set) var lastError: String?

    private let engine: SuggestionEngine
    private let defaults: UserDefaults
    private let rebuildSources: () -> Void

    private static let activeKey = "TypeAhead.model.active"

    /// - Parameter rebuildSources: called after a swap so the engine can be
    ///   reassembled with the new model in place. The registry deliberately does
    ///   not know the order sources are registered in — that is the composition
    ///   root's business.
    public init(engine: SuggestionEngine,
                defaults: UserDefaults = .standard,
                rebuildSources: @escaping () -> Void) {
        self.engine = engine
        self.defaults = defaults
        self.rebuildSources = rebuildSources
        self.activeEntryID = defaults.string(forKey: ModelRegistry.activeKey)
            ?? ModelRegistry.defaultEntryID
    }

    // MARK: - Storage

    public static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("TypeAhead/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Whether llama.cpp already has this model cached.
    ///
    /// Its cache, not ours — the app no longer downloads anything itself, so
    /// "installed" means "llama.cpp will not need the network".
    public func isInstalled(_ entry: CatalogEntry) -> Bool {
        guard !entry.repo.isEmpty else { return true }
        return ModelRegistry.cachedPath(for: entry) != nil
    }

    /// Where llama.cpp put a downloaded model, if it has one.
    ///
    /// The standard Hugging Face layout — `~/.cache/huggingface/hub/models--<org>--<name>/
    /// snapshots/<revision>/<file>` — not a llama.cpp-specific directory. Checking
    /// the wrong path made every catalog entry report itself as not downloaded even
    /// once it was.
    public static func cachedPath(for entry: CatalogEntry) -> URL? {
        let folder = "models--" + entry.repo.replacingOccurrences(of: "/", with: "--")
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(folder)/snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return nil }

        for revision in revisions {
            let candidate = revision.appendingPathComponent(entry.file)
            // Resolves the symlink Hugging Face leaves in snapshots/, and checks
            // the header — a partial download is a file too.
            if FileManager.default.fileExists(atPath: candidate.path),
               GGUFModel.isValidGGUF(path: candidate.resolvingSymlinksInPath().path) {
                return candidate
            }
        }
        return nil
    }

    /// Every GGUF present, including ones added by hand — so "Add model…" needs no
    /// separate bookkeeping.
    public func installedModelPaths() -> [URL] {
        guard let directory = try? ModelRegistry.modelsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return [] }
        return contents.filter { $0.pathExtension.lowercased() == "gguf" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    // MARK: - Activation

    /// Loads a model, or unloads to memory-only when `path` is nil.
    ///
    /// Never throws on failure: a model that will not load leaves the app running
    /// on memory alone, which is a working app. Rule 2 — the model degrades, it
    /// never blocks.
    @discardableResult
    public func activate(path: URL?, entryID: String) -> Bool {
        active?.stop()
        active = nil

        defer {
            activeEntryID = entryID
            defaults.set(entryID, forKey: ModelRegistry.activeKey)
            rebuildSources()
        }

        guard let path else { return true }
        guard GGUFModel.isRuntimeAvailable else {
            lastError = "llama-server is not installed. Try: brew install llama.cpp"
            return false
        }

        let model = GGUFModel(name: path.deletingPathExtension().lastPathComponent,
                              source: .local(path: path.path))
        guard model.start() else {
            lastError = model.lastError
            return false
        }
        active = model
        lastError = nil
        return true
    }

    /// Activates a catalog entry, letting llama.cpp fetch it if this is the first
    /// use. Blocking and potentially slow — the caller runs it off the main thread.
    public func activate(_ entry: CatalogEntry) -> Bool {
        guard !entry.repo.isEmpty else { return activate(path: nil, entryID: entry.id) }
        guard GGUFModel.isRuntimeAvailable else {
            lastError = "llama-server is not installed. Try: brew install llama.cpp"
            return false
        }

        active?.stop()
        active = nil

        let model = GGUFModel(name: entry.displayName,
                              source: .huggingFace(repo: entry.repo, file: entry.file))
        let started = model.start()
        if started {
            active = model
            lastError = nil
        } else {
            lastError = model.lastError
        }
        activeEntryID = started ? entry.id : "none"
        defaults.set(activeEntryID, forKey: ModelRegistry.activeKey)
        rebuildSources()
        return started
    }

    /// Restores the model chosen last session. Called at launch.
    ///
    /// Loads in place when the weights are already on disk — memory-mapping a
    /// cached model is fast enough to do before the first keystroke. When they
    /// are not, the fetch runs in the background and the app starts on memory
    /// alone, exactly as it always did, then picks the model up when it arrives.
    ///
    /// This split is what lets the model be on by default. Making it default
    /// without it would put a 640MB download in front of first launch, and an
    /// app that hangs on startup gets uninstalled before it ever suggests
    /// anything.
    public func restoreActive() {
        guard activeEntryID != "none" else { return }

        if let entry = ModelRegistry.catalog.first(where: { $0.id == activeEntryID }) {
            if isInstalled(entry) {
                _ = activate(entry)
            } else {
                downloadInBackground(entry)
            }
            return
        }
        if let custom = installedModelPaths().first(where: {
            $0.deletingPathExtension().lastPathComponent == activeEntryID
        }) {
            _ = activate(path: custom, entryID: activeEntryID)
        }
    }

    /// Whether a first-run fetch is in flight, so the menu can say so rather than
    /// showing "no model" and looking broken.
    public private(set) var isFetching = false

    private func downloadInBackground(_ entry: CatalogEntry) {
        guard GGUFModel.isRuntimeAvailable else {
            lastError = "llama-server is not installed. Try: brew install llama.cpp"
            return
        }
        isFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let started = self.activate(entry)
            DispatchQueue.main.async {
                self.isFetching = false
                // A failed first fetch must not strand the app pointing at a model
                // it does not have: fall back to memory-only and say why.
                if !started { _ = self.activate(path: nil, entryID: "none") }
                self.rebuildSources()
            }
        }
    }

    /// Copies a user-supplied GGUF into the models directory and activates it.
    public func addLocalModel(at source: URL) throws -> Bool {
        let directory = try ModelRegistry.modelsDirectory()
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return activate(path: destination,
                        entryID: destination.deletingPathExtension().lastPathComponent)
    }

    // Downloading is deliberately not implemented here any more. The previous
    // version saved whatever bytes came back — including "Invalid username or
    // password." — as a .gguf, and then reported it as installed. llama.cpp's own
    // -hf downloader resolves, verifies and caches, and is exercised by every
    // llama.cpp user daily.

}


