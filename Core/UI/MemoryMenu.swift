import Cocoa

/// Menu entries for the memory store: export, import, review, and the
/// pause-learning switch.
///
/// A `MenuContributor`, so the menu bar does not need to know these exist.
public final class MemoryMenu: NSObject, MenuContributor {
    public let menuTitle = "Memory"

    private let store: Store
    private let portability: Portability
    private let settings: Settings
    private var reviewWindow: MemoryReviewWindow?

    public init(store: Store, settings: Settings) {
        self.store = store
        self.portability = Portability(store: store)
        self.settings = settings
    }

    public func makeMenuItems() -> [NSMenuItem] {
        let review = NSMenuItem(title: "Review what it knows…",
                                action: #selector(showReview),
                                keyEquivalent: "")
        review.target = self

        let export = NSMenuItem(title: "Export memory…",
                                action: #selector(exportMemory),
                                keyEquivalent: "")
        export.target = self

        let importItem = NSMenuItem(title: "Import memory…",
                                    action: #selector(importMemory),
                                    keyEquivalent: "")
        importItem.target = self

        let pause = NSMenuItem(title: settings.isLearningPaused ? "Resume learning" : "Pause learning",
                               action: #selector(toggleLearning),
                               keyEquivalent: "")
        pause.target = self
        pause.state = settings.isLearningPaused ? .on : .off

        let forget = NSMenuItem(title: "Forget my typos…",
                                action: #selector(forgetTypos),
                                keyEquivalent: "")
        forget.target = self

        return [review, forget, export, importItem, pause]
    }

    /// Purges words that never recurred. Real words, names and Hinglish survive
    /// because they recur by definition; typos do not.
    @objc private func forgetTypos() {
        let count = (try? store.database.query(
            "SELECT COUNT(*) AS c FROM vocab WHERE kind = 'unverified' AND count < ?",
            [.integer(Int64(WordHygiene.unknownWordThreshold))]).first?.int("c")) ?? 0

        let alert = NSAlert()
        alert.messageText = "Forget \(count) unverified words?"
        alert.informativeText = """
            These are words the dictionary does not recognise and that you have not \
            typed often enough for them to be real — typos, and fragments left when \
            a keystroke was missed.

            Names, jargon and Hinglish are kept: they recur, which is exactly what \
            tells them apart from a typo.
            """
        alert.addButton(withTitle: "Forget them")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removed = (try? store.forgetUnverified(
            seenFewerThan: WordHygiene.unknownWordThreshold)) ?? 0
        MemoryMenu.inform("Forgot \(removed) words", "Your real vocabulary is untouched.")
    }

    @objc private func showReview() {
        let window = reviewWindow ?? MemoryReviewWindow(store: store)
        reviewWindow = window
        window.present()
    }

    @objc private func toggleLearning() {
        settings.isLearningPaused.toggle()
    }

    @objc private func exportMemory() {
        // The review step is not optional. For a tool that watches every text box,
        // being able to see exactly what is about to leave the machine — and drop
        // any of it — is the difference between a feature and a liability.
        let review = ExportReviewSheet(store: store)
        guard let options = review.runModal() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "typeahead-memory-\(MemoryMenu.dateStamp()).\(Portability.fileExtension)"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manifest = try portability.export(to: url, options: options)
            MemoryMenu.inform(
                "Memory exported",
                """
                \(manifest.wordCount) words, \(manifest.snippetCount) snippets, \
                \(manifest.identityCount) identity facts.

                Copy this file to your other Mac and choose Import memory there. \
                Importing merges — it will not overwrite what that Mac already knows.
                """)
        } catch {
            MemoryMenu.inform("Export failed", "\(error)")
        }
    }

    @objc private func importMemory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let summary = try portability.importMemory(from: url)
            var message = """
                \(summary.wordsAdded) new words, \(summary.wordsMerged) merged.
                \(summary.snippetsMerged) snippets, \(summary.identityFactsMerged) identity facts, \
                \(summary.correctionsMerged) corrections.
                \(summary.ngramsMerged) statistics merged.
                """
            if !summary.conflictingKeys.isEmpty {
                message += """


                    Both values kept for: \(summary.conflictingKeys.joined(separator: ", ")).
                    Neither Mac's value was discarded — open Review to pick.
                    """
            }
            MemoryMenu.inform("Memory imported", message)
        } catch {
            MemoryMenu.inform("Import failed", "\(error)")
        }
    }

    static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func inform(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// The pre-export review: what is about to leave this machine, and what to hold
/// back.
final class ExportReviewSheet {
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    /// Returns the chosen options, or nil if the user cancelled.
    func runModal() -> Portability.ExportOptions? {
        let identity = (try? store.identityFacts(confirmedOnly: true)) ?? []
        let vocab = (try? store.allVocab()) ?? []
        let snippets = ((try? store.allSnippets()) ?? []).filter {
            $0.source == "manual" || $0.count >= SnippetMiner.promotionThreshold
        }
        let corrections = (try? store.allCorrections()) ?? []

        let alert = NSAlert()
        alert.messageText = "Review before exporting"
        alert.informativeText = """
            This file will contain:

            • \(identity.count) identity facts\(identity.isEmpty ? "" : " — " + identity.prefix(3).map(\.value).joined(separator: ", ") + (identity.count > 3 ? ", …" : ""))
            • \(vocab.count) words and names
            • \(snippets.count) phrases you repeat
            • \(corrections.count) typo corrections
            • your typing statistics

            No model weights and nothing model-specific, so it imports on any Mac \
            regardless of which model is installed there.
            """
        alert.alertStyle = .informational

        let includeIdentity = NSButton(checkboxWithTitle: "Include identity facts (emails, phone, addresses)",
                                       target: nil, action: nil)
        includeIdentity.state = .on
        alert.accessoryView = includeIdentity

        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Portability.ExportOptions(includeIdentity: includeIdentity.state == .on)
    }
}
