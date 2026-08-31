import Cocoa

/// "What does this thing actually know about me?"
///
/// A tool that watches every text box has to be able to answer that question, in
/// full, and let the answer be edited. Everything here is deletable.
public final class MemoryReviewWindow: NSObject, NSWindowDelegate {
    private let store: Store
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var rows: [Row] = []
    private var scope: Scope = .identity

    private enum Scope: Int, CaseIterable {
        case identity, vocabulary, snippets, corrections

        var title: String {
            switch self {
            case .identity: return "Identity"
            case .vocabulary: return "Words & names"
            case .snippets: return "Phrases"
            case .corrections: return "Corrections"
            }
        }
    }

    private struct Row {
        let primary: String
        let secondary: String
        let delete: () throws -> Void
    }

    public init(store: Store) {
        self.store = store
        super.init()
    }

    public func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TypeAhead Memory"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]

        let picker = NSSegmentedControl(labels: Scope.allCases.map(\.title),
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(scopeChanged(_:)))
        picker.selectedSegment = 0
        picker.frame = NSRect(x: 16, y: container.bounds.height - 44, width: 528, height: 24)
        picker.autoresizingMask = [.width, .minYMargin]
        container.addSubview(picker)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 52,
                                                width: 528,
                                                height: container.bounds.height - 108))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.headerView = nil
        let primary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("primary"))
        primary.width = 340
        let secondary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("secondary"))
        secondary.width = 160
        table.addTableColumn(primary)
        table.addTableColumn(secondary)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        container.addSubview(scroll)
        tableView = table

        let delete = NSButton(title: "Forget selected",
                              target: self,
                              action: #selector(deleteSelected))
        delete.frame = NSRect(x: 16, y: 12, width: 140, height: 28)
        delete.autoresizingMask = [.maxXMargin]
        container.addSubview(delete)

        let note = NSTextField(labelWithString:
            "Nothing here is in a model. Deleting removes it permanently.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 168, y: 17, width: 376, height: 18)
        note.autoresizingMask = [.width]
        container.addSubview(note)

        window.contentView = container
        self.window = window

        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        scope = Scope(rawValue: sender.selectedSegment) ?? .identity
        reload()
    }

    @objc private func deleteSelected() {
        guard let table = tableView else { return }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        guard !selected.isEmpty else { return }
        for row in selected { try? row.delete() }
        reload()
    }

    private func reload() {
        switch scope {
        case .identity:
            rows = ((try? store.identityFacts(confirmedOnly: false)) ?? []).map { fact in
                Row(primary: fact.value,
                    secondary: fact.confirmed ? fact.key : "\(fact.key) — unconfirmed",
                    delete: { [store] in try store.deleteIdentity(key: fact.key, value: fact.value) })
            }
        case .vocabulary:
            rows = ((try? store.allVocab()) ?? []).prefix(500).map { entry in
                Row(primary: entry.word,
                    secondary: "\(entry.count)×\(entry.isProtected ? " · protected" : "")",
                    delete: { [store] in
                        try store.database.execute("DELETE FROM vocab WHERE word = ?",
                                                   [.text(entry.word)])
                    })
            }
        case .snippets:
            rows = ((try? store.allSnippets()) ?? [])
                .filter { $0.source == "manual" || $0.count >= SnippetMiner.promotionThreshold }
                .map { snippet in
                    Row(primary: snippet.text,
                        secondary: "\(snippet.count)×",
                        delete: { [store] in try store.deleteSnippet(snippet.text) })
                }
        case .corrections:
            rows = ((try? store.allCorrections()) ?? []).map { pair in
                Row(primary: "\(pair.wrong) → \(pair.right)",
                    secondary: "\(pair.count)×",
                    delete: { [store] in
                        try store.database.execute(
                            "DELETE FROM correction WHERE wrong = ? AND right = ?",
                            [.text(pair.wrong), .text(pair.right)])
                    })
            }
        }
        tableView?.reloadData()
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
        tableView = nil
    }
}

extension MemoryReviewWindow: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let text = tableColumn?.identifier.rawValue == "secondary"
            ? rows[row].secondary
            : rows[row].primary

        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 12)
        if tableColumn?.identifier.rawValue == "secondary" {
            field.textColor = .secondaryLabelColor
        }
        return field
    }
}
