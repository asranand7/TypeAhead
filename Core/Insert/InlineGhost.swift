import ApplicationServices
import Cocoa

/// Shows the suggestion *inside* the text field, selected, and takes it back out
/// safely.
///
/// ## What went wrong the first time
///
/// The first version had two strategies: write through Accessibility, or type the
/// text and select it with Shift+Left. Removal was by *position* — re-assert the
/// remembered range, then delete it — with a guard that bailed out if the document
/// no longer looked as expected.
///
/// Both halves were wrong. The typing strategy cannot verify anything: it writes
/// blind and deletes blind, so when an app collapsed the selection on its own (a
/// React re-render does this constantly) one Delete took a single character and
/// left the rest behind. And the Accessibility strategy's bail-out silently
/// abandoned the ghost in place. Either way stray text became real text, was
/// learned as if the user had typed it, and fed back: "make" following "make",
/// snippets reading "Make I When I write Make".
///
/// ## What makes this version safe
///
/// One strategy, Accessibility only, and **removal is verified by content, never
/// by position**. The exact characters that were inserted are remembered, and a
/// deletion happens only after reading the field back and confirming those exact
/// characters are still at exactly that offset. Nothing is searched for: a short
/// suggestion like "the" occurs in the user's own writing too, and a search finds
/// theirs. If the confirmation fails, nothing is deleted — a leftover suggestion
/// is a visible annoyance, but deleting the wrong range destroys what someone
/// wrote, and they cannot get it back.
///
/// Apps that refuse Accessibility writes get the floating pill instead. That is
/// most terminals; it is not Claude, Slack or VS Code, which expose a writable
/// text area once their accessibility tree is woken.
public final class InlineGhost {
    private let systemWide = AXUIElementCreateSystemWide()

    /// How the ghost got into the document, because taking it out differs.
    private enum Route { case accessibility, typed }

    /// The exact text inserted, where it was put, and how it got there.
    private var ghost: (text: String, location: Int, route: Route)?
    private let inserter = Inserter()

    /// Records why an insertion attempt succeeded or failed.
    ///
    /// "It does not work in app X" has half a dozen possible causes that look
    /// identical from outside — no focused element, a non-empty selection, a caret
    /// that is not at the end, a refused write, a write that did not stick. Only
    /// the app holds Accessibility permission, so only the app can tell them apart.
    public static let logPath = NSHomeDirectory()
        + "/Library/Application Support/TypeAhead/inline.log"

    private static func log(_ reason: String) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(app): \(reason)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }

    public init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
    }

    public var isShowing: Bool { ghost != nil }

    /// True when the ghost was *typed* and starts with whitespace.
    ///
    /// This combination is dangerous in a way that is entirely macOS's doing. A
    /// snippet completing "Make" from "Make it" is " it" — with a leading space —
    /// and typing it puts a synthetic space into the input stream. If the user's
    /// next key is also a space, the system's "double-space inserts a period"
    /// substitution fires and silently turns the pair into ". ".
    ///
    /// The caller uses this to take the explicit-removal path instead of letting
    /// the app replace the selection, which puts deletions between the two spaces
    /// and breaks the adjacency the substitution is watching for.
    public var typedLeadingWhitespace: Bool {
        guard let ghost, ghost.route == .typed else { return false }
        return ghost.text.first?.isWhitespace == true
    }

    /// Forgets the ghost without touching the document.
    ///
    /// Used when the app itself will dispose of it: a selected range is replaced
    /// by whatever the user types next, in every text field there is. Relying on
    /// that rather than deleting first removes an entire class of failure — most
    /// keystrokes now involve no mutation from us at all.
    public func relinquish() {
        ghost = nil
    }

    // MARK: - Element access

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func value(of element: AXUIElement) -> [UInt16]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &ref) == .success,
              let text = ref as? String else { return nil }
        return Array(text.utf16)
    }

    @discardableResult
    private func setRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    // MARK: - Showing

    /// Inserts `text` at the caret and selects it. False means the app would not
    /// take it, and the caller should fall back to the pill.
    @discardableResult
    public func show(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        remove()

        guard let element = focusedElement() else {
            InlineGhost.log("no focused element")
            return false
        }
        guard let caret = selectedRange(element) else {
            InlineGhost.log("focused element reports no selection range")
            return false
        }
        guard caret.location != NSNotFound else {
            InlineGhost.log("selection location is NSNotFound")
            return false
        }
        guard caret.length == 0 else {
            InlineGhost.log("text is selected (length \(caret.length)); not inserting")
            return false
        }

        // Only at the very end of the field.
        //
        // This is the constraint that makes the whole feature safe. A ghost placed
        // mid-paragraph, if it ever fails to come out, has buried itself inside
        // the user's writing. A ghost at the end is trailing text: visible,
        // obviously not theirs, and removed by the next character they type.
        // It also happens to be where a suggestion is wanted essentially always.
        guard let existing = value(of: element) else {
            InlineGhost.log("element exposes no value; cannot confirm caret is at the end")
            return false
        }
        guard caret.location >= existing.count else {
            InlineGhost.log("caret at \(caret.location) of \(existing.count) — not at the end")
            return false
        }

        let writeStatus = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard writeStatus == .success else {
            InlineGhost.log("write refused (AXError \(writeStatus.rawValue))")
            return false
        }

        let length = text.utf16.count
        guard setRange(element, location: caret.location, length: length) else {
            ghost = (text, caret.location, .accessibility)
            remove()
            return false
        }

        // A successful write is not proof the text is on screen: a React-controlled
        // field accepts it and reverts on the next render. Read it back.
        guard let contents = value(of: element),
              InlineGhost.slice(contents, at: caret.location, length: length) == text else {
            // React-controlled fields — Claude, Slack, Notion — accept the write
            // and revert it on their next render, because their virtual DOM never
            // learned about it. No Accessibility write will ever survive that.
            //
            // Real keystrokes do survive: React processes them as genuine input.
            // So type it instead, and select it back.
            ghost = (text, caret.location, .accessibility)
            remove()
            return showByTyping(text, at: caret.location)
        }

        InlineGhost.log("OK — inserted \(length) chars at \(caret.location)")
        ghost = (text, caret.location, .accessibility)
        return true
    }

    /// Types the ghost and selects it back with Shift+Left.
    ///
    /// Safe only because the ghost is always at the very end of the field. That
    /// makes removal deterministic: the ghost is the last N characters, so
    /// "collapse to the end, then delete N" is correct whatever the app has done
    /// to the selection meanwhile. Without the end-of-field rule this would be the
    /// blind deletion that corrupted text earlier.
    /// Withdrawn. Kept as a record of why, because the idea keeps looking
    /// attractive and it is not.
    ///
    /// Typing the suggestion and selecting it back is the only way to show text
    /// inside a React-controlled field, since those revert every Accessibility
    /// write. It works in a demo and cannot be made safe in use: synthetic key
    /// events enter the same input stream as the user's own and are delivered
    /// asynchronously, so a preview shown every 40ms and withdrawn on the next
    /// keystroke interleaves with real typing in ways no amount of verification
    /// fixes. In twenty seconds of ordinary use it typed and deleted ghosts
    /// dozens of times and left "Make  is doing se   see" behind.
    ///
    /// Each round of fixes closed one interleaving and revealed another — a stray
    /// period from a system substitution, a stranded ghost from a read racing the
    /// insertion, duplicated fragments from deletions racing keystrokes. The
    /// pattern is the tell: the mechanism is wrong, not its details.
    ///
    /// The correct way to render text inside another app's field is an input
    /// method's marked text, where the app draws the suggestion and no synthetic
    /// keystroke exists. That remains the destination.
    private func showByTyping(_ text: String, at location: Int) -> Bool {
        InlineGhost.log("declined: app reverts Accessibility writes, and typing is unsafe")
        return false
    }

    // MARK: - Accepting

    /// Keeps the text and collapses the selection so the caret lands after it.
    @discardableResult
    public func accept() -> Bool {
        guard let ghost else { return false }
        defer { self.ghost = nil }

        if ghost.route == .typed {
            // Right arrow collapses a selection to its end in every text field.
            inserter.collapseSelectionForward()
            return true
        }
        guard let element = focusedElement() else { return false }
        return setRange(element,
                        location: ghost.location + ghost.text.utf16.count,
                        length: 0)
    }

    // MARK: - Removing

    /// Takes the ghost back out — but only after confirming the exact characters
    /// inserted are still there.
    ///
    /// This is the whole safety argument. Deleting by remembered position assumes
    /// the document has not moved, and when that assumption broke the app deleted
    /// the wrong thing or nothing at all. Matching on content cannot delete the
    /// user's own writing, because it only ever removes a range it has just read
    /// and confirmed.
    public func remove() {
        guard let ghost else { return }
        self.ghost = nil

        guard let element = focusedElement(),
              let contents = value(of: element) else { return }

        if ghost.route == .typed {
            // Verified by content before a single key is sent: the ghost must
            // still be the tail of the field. If the app changed things underneath
            // us, nothing is deleted.
            let needle = Array(ghost.text.utf16)
            guard contents.count >= needle.count,
                  InlineGhost.slice(contents,
                                    at: contents.count - needle.count,
                                    length: needle.count) == ghost.text else {
                InlineGhost.log("typed ghost is no longer the tail; leaving it alone")
                return
            }
            // Collapse to the end first, so the deletion starts from a known place
            // whatever the app did to the selection.
            inserter.collapseSelectionForward()
            inserter.deletePreviousCharacters(needle.count)
            return
        }

        guard let location = InlineGhost.locate(ghost.text, in: contents, near: ghost.location) else {
            // Cannot find it. Leaving a stray suggestion visible is bad; deleting
            // a range that might be the user's own text is far worse.
            return
        }

        guard setRange(element, location: location, length: ghost.text.utf16.count) else { return }

        // Re-read: the selection must contain exactly the ghost before anything is
        // deleted. Setting a range can be quietly ignored, and this is the last
        // point at which that can still be caught.
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let confirmed = selected as? String, confirmed == ghost.text else {
            // Put the caret back where it was rather than leave a stray selection
            // the next keystroke would overwrite.
            setRange(element, location: location + ghost.text.utf16.count, length: 0)
            return
        }

        _ = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef)
    }

    // MARK: - Searching

    /// Confirms the ghost is at `expected`, and nowhere else.
    ///
    /// Deliberately does **not** search for it. An earlier version scanned a
    /// window either side to survive an app reflowing its content, and that was a
    /// serious mistake: a short suggestion like "the" or "ing" also occurs in the
    /// user's own writing, so the scan would find *their* text and delete that
    /// instead. Overwriting what someone has written is far worse than leaving a
    /// stray suggestion on screen.
    ///
    /// So the only accepted answer is "exactly where it was put, character for
    /// character". Anything else means the document moved under us, and the safe
    /// response is to do nothing at all.
    public static func locate(_ text: String, in contents: [UInt16], near expected: Int) -> Int? {
        let needle = Array(text.utf16)
        guard !needle.isEmpty, needle.count <= contents.count else { return nil }
        return slice(contents, at: expected, length: needle.count) == text ? expected : nil
    }

    public static func slice(_ contents: [UInt16], at location: Int, length: Int) -> String? {
        guard location >= 0, length > 0, location + length <= contents.count else { return nil }
        return String(decoding: contents[location..<(location + length)], as: UTF16.self)
    }
}
