import Cocoa

/// "What does this thing actually know about me?"
///
/// A tool that watches every text box has to be able to answer that question, in
/// full, and let the answer be edited. Everything here is deletable.
public final class MemoryReviewWindow: NSObject, NSWindowDelegate {
    private let store: Store
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var emptyLabel: NSTextField?
    private var countLabel: NSTextField?
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

    /// What this window says when a tab holds nothing.
    ///
    /// An empty `NSTableView` still draws its alternating row stripes, so a tab
    /// with no rows looked exactly like a tab whose rows had failed to render —
    /// blank grey bands and no explanation. For the one screen that exists to
    /// answer "what do you know about me", "nothing yet, and here is why" and
    /// "something went wrong" must not look the same.
    private func emptyMessage(for scope: Scope) -> String {
        switch scope {
        case .identity:
            return "Nothing yet.\n\nYour email and phone are offered only after you confirm them."
        case .vocabulary:
            return "Nothing yet.\n\nWords appear here as you type them."
        case .snippets:
            return "Nothing yet.\n\nA phrase is recorded once you type the same "
                + "three or more words twice inside one sentence."
        case .corrections:
            return "Nothing yet.\n\nTypo pairs are learned when you delete a word and retype it."
        }
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

        // 130, not 108: the extra 22pt is the count line's strip. Sizing the
        // table to the old height and then placing the count inside that range
        // put the text on top of the first row.
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 52,
                                                width: 528,
                                                height: container.bounds.height - 130))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.headerView = nil
        let primary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("primary"))
        primary.width = 310
        let secondary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("secondary"))
        // Wide enough for the longest status this column carries. At 160 it
        // truncated to "not suggeste.", which reads as a rendering fault.
        secondary.width = 200
        table.addTableColumn(primary)
        table.addTableColumn(secondary)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        container.addSubview(scroll)
        tableView = table

        let empty = NSTextField(wrappingLabelWithString: "")
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.isSelectable = false
        empty.frame = NSRect(x: scroll.frame.minX + 40,
                             y: scroll.frame.midY - 40,
                             width: scroll.frame.width - 80,
                             height: 80)
        empty.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        empty.isHidden = true
        container.addSubview(empty)
        emptyLabel = empty

        // How much is actually here, against how much is on offer. The two differ
        // and the difference is the point: a phrase seen once is remembered but
        // not yet suggested, and this window is supposed to show what is
        // remembered.
        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.frame = NSRect(x: 16, y: container.bounds.height - 70, width: 528, height: 16)
        count.autoresizingMask = [.width, .minYMargin]
        container.addSubview(count)
        countLabel = count

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
        guard confirmDeletion(of: selected) else { return }
        for row in selected { try? row.delete() }
        reload()
    }

    /// Names what is about to go, and what goes with it.
    ///
    /// There was no confirmation at all: a click deleted whatever happened to be
    /// selected, permanently, with the only warning a line of grey text at the
    /// bottom of the window. That was thin before and is wrong now — forgetting a
    /// word no longer removes just the word. It has to take the statistics that
    /// referred to it and the phrases containing it, because leaving those behind
    /// re-points them at the next word learned. So the button does more than its
    /// label suggests, and the dialog is where that gets said.
    private func confirmDeletion(of selected: [Row]) -> Bool {
        let sample = selected.prefix(5).map(\.primary).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = selected.count == 1
            ? "Forget \u{201C}\(selected[0].primary)\u{201D}?"
            : "Forget \(selected.count) items?"
        alert.informativeText = (selected.count > 1 ? "\(sample)"
            + (selected.count > 5 ? ", and \(selected.count - 5) more.\n\n" : ".\n\n") : "")
            + consequence(for: scope)
            + "\n\nThis cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What else disappears, per tier. Only the vocabulary tab cascades.
    private func consequence(for scope: Scope) -> String {
        switch scope {
        case .vocabulary:
            return "The statistics that predicted from this word go too, along with "
                + "any phrase containing it — otherwise they would point at whatever "
                + "word is learned next."
        case .snippets:
            return "The phrase stops being suggested. The words in it are kept."
        case .identity:
            return "It will no longer be offered as a completion."
        case .corrections:
            return "The typo will stop being corrected automatically."
        }
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
            // No cap. It used to stop at 500, silently, with 741 words in the
            // store — so 241 of the user's own words could be neither seen nor
            // deleted here. NSTableView is view-based and recycles its rows, so
            // the full list costs nothing to show.
            rows = ((try? store.allVocab()) ?? []).map { entry in
                Row(primary: entry.word,
                    secondary: "\(entry.count)×\(entry.isProtected ? " · protected" : "")",
                    // Not a bare DELETE: see Store.forgetWord. Removing the row
                    // alone frees its id for the next word learned and silently
                    // re-points every n-gram that referred to it.
                    delete: { [store] in try store.forgetWord(entry.word) })
            }
        case .snippets:
            // Every phrase held, not only the promoted ones. The filter here used
            // to mirror what `SnippetSource` will offer, which made the tab read
            // as empty while 128 mined phrases sat in the store — remembered,
            // invisible, and impossible to delete. What is offered and what is
            // remembered are different questions, and this window is about the
            // second one.
            rows = ((try? store.allSnippets()) ?? [])
                .map { snippet in
                    let offered = snippet.source == "manual"
                        || snippet.count >= SnippetMiner.promotionThreshold
                    return Row(primary: snippet.text,
                               secondary: offered
                                   ? "\(snippet.count)× · suggested"
                                   : "seen once · not yet",
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

        emptyLabel?.stringValue = emptyMessage(for: scope)
        emptyLabel?.isHidden = !rows.isEmpty
        // See the Apps pane: stripes painted over empty space look like rows that
        // failed to render, and they sit behind the empty message.
        tableView?.usesAlternatingRowBackgroundColors = !rows.isEmpty
        countLabel?.stringValue = rows.isEmpty ? "" : summary()
    }

    /// "128 phrases · none suggested yet" — the count, and how much of it is live.
    private func summary() -> String {
        let noun: String
        switch scope {
        case .identity:    noun = rows.count == 1 ? "fact" : "facts"
        case .vocabulary:  noun = rows.count == 1 ? "word" : "words"
        case .snippets:    noun = rows.count == 1 ? "phrase" : "phrases"
        case .corrections: noun = rows.count == 1 ? "pair" : "pairs"
        }
        guard scope == .snippets else { return "\(rows.count) \(noun)" }

        let live = rows.filter { $0.secondary.hasSuffix("suggested") }.count
        return live == 0
            ? "\(rows.count) \(noun) · none suggested yet"
            : "\(rows.count) \(noun) · \(live) suggested"
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
        tableView = nil
        emptyLabel = nil
        countLabel = nil
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
