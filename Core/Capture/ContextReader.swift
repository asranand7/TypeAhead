import ApplicationServices
import Cocoa

/// Reads the text sitting immediately before the caret.
///
/// Two strategies, in order of trust:
///
/// 1. **Accessibility.** Ask the focused element for its value and selection. This
///    is authoritative — it sees text the user pasted, arrowed into, or typed
///    before the app launched.
/// 2. **Shadow buffer.** A local echo of recent keystrokes, used when the focused
///    app refuses Accessibility. Terminals and canvas editors (Google Docs) are
///    the usual refusers. It drifts the moment the user clicks or arrows around,
///    so it is invalidated aggressively rather than trusted.
///
/// The plan's manual app matrix exists to find out which apps land in which bucket.
public final class ContextReader {
    /// How much text before the caret to hand the predictor. Enough for n-gram
    /// context and snippet matching; small enough that copying it is free.
    public static let maxContextChars = 200

    /// Accessibility calls block until the target app answers. A hung app must not
    /// hang typing, so cap the wait well under the 40ms prediction debounce.
    private static let messagingTimeout: Float = 0.035

    private var shadow = ""
    private let systemWide = AXUIElementCreateSystemWide()

    /// Labelled fields around the caret, and when they were last read.
    ///
    /// Cached because this is a tree walk, not a single attribute fetch, and it
    /// must never run on the keystroke path at full cost. A subject line does not
    /// change while you type the body, so re-reading it per keystroke would buy
    /// nothing for several milliseconds of Accessibility round trips.
    private var ambient: [TypingContext.AmbientField] = []
    private var ambientReadAt: Date?
    private let ambientLock = NSLock()

    public init() {
        AXUIElementSetMessagingTimeout(systemWide, ContextReader.messagingTimeout)
    }

    // MARK: - Shadow buffer upkeep

    public func noteTyped(_ characters: String) {
        shadow += characters
        if shadow.count > ContextReader.maxContextChars {
            shadow.removeFirst(shadow.count - ContextReader.maxContextChars)
        }
    }

    public func noteBackspace() {
        if !shadow.isEmpty { shadow.removeLast() }
    }

    /// Called on anything that moves the caret somewhere we did not put it:
    /// focus changes, mouse clicks, arrow keys. The shadow buffer cannot track
    /// those, and stale context is worse than no context.
    public func invalidateShadow() {
        shadow = ""
        // The window around the caret may be a different one entirely now.
        ambientLock.lock()
        ambient = []
        ambientReadAt = nil
        ambientLock.unlock()
    }

    // MARK: - Reading

    public func read() -> TypingContext {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let split = accessibilityTextAroundCaret() {
            return TypingContext(
                textBeforeCaret: split.before,
                currentWordPrefix: ContextReader.trailingWord(of: split.before),
                appBundleID: bundleID,
                isAuthoritative: true,
                textAfterCaret: split.after,
                ambientContext: ambientFields()
            )
        }

        // The shadow buffer is a log of keystrokes, so there is nothing after the
        // caret to report — not "the caret is at the end", simply "unknown".
        return TypingContext(
            textBeforeCaret: shadow,
            currentWordPrefix: ContextReader.trailingWord(of: shadow),
            appBundleID: bundleID,
            isAuthoritative: false
        )
    }

    // MARK: - Ambient context

    /// How long a set of ambient fields is reused before being re-read.
    ///
    /// Focus changes clear the cache outright, so this only bounds the case where
    /// the user stays in one field while the window around it changes — a new
    /// message arriving in a thread, say. Long enough to cost nothing, short
    /// enough that stale context does not survive a conversation.
    private static let ambientLifetime: TimeInterval = 20

    /// The most fields worth carrying. A window can expose dozens of labelled
    /// strings and almost all of them are chrome; the useful ones — subject,
    /// recipient, channel — are few and near the top.
    private static let maxAmbientFields = 4

    /// How much of one field to keep.
    private static let maxAmbientValueChars = 120

    /// Nodes visited before giving up. A hard cap rather than a time budget,
    /// because the cost here is Accessibility round trips and the count is what
    /// actually bounds them.
    private static let maxAmbientNodes = 60

    private func ambientFields() -> [TypingContext.AmbientField] {
        ambientLock.lock()
        let cached = ambient
        let fresh = ambientReadAt.map {
            Date().timeIntervalSince($0) < ContextReader.ambientLifetime
        } ?? false
        ambientLock.unlock()
        if fresh { return cached }

        let found = readAmbientFields()
        ambientLock.lock()
        ambient = found
        ambientReadAt = Date()
        ambientLock.unlock()
        return found
    }

    /// Walks up from the caret to the window and collects labelled text.
    ///
    /// Deliberately shallow and deliberately capped. A full traversal of a mail
    /// window is thousands of nodes and every one is a blocking cross-process
    /// call; what is wanted is the handful of labelled fields a compose window
    /// puts near the top, which are within a few levels of the text area.
    private func readAmbientFields() -> [TypingContext.AmbientField] {
        guard let focused = focusedElement() else { return [] }

        // Up to the enclosing window, or as far as the chain goes.
        var root = focused
        for _ in 0..<6 {
            guard let parent = element(root, attribute: kAXParentAttribute) else { break }
            AXUIElementSetMessagingTimeout(parent, ContextReader.messagingTimeout)
            root = parent
            if string(parent, attribute: kAXRoleAttribute) == kAXWindowRole as String { break }
        }
        guard root != focused else { return [] }

        var found: [TypingContext.AmbientField] = []
        var seen = Set<String>()
        var budget = ContextReader.maxAmbientNodes
        var queue: [(AXUIElement, Int)] = [(root, 0)]

        while !queue.isEmpty, budget > 0, found.count < ContextReader.maxAmbientFields {
            let (node, depth) = queue.removeFirst()
            budget -= 1
            if depth > 4 { continue }

            // The field being typed into is already the main context; including it
            // again would just duplicate the prompt.
            if node != focused, let field = ambientField(of: node),
               !seen.contains(field.label) {
                seen.insert(field.label)
                found.append(field)
            }

            guard let children = elements(node, attribute: kAXChildrenAttribute) else { continue }
            for child in children.prefix(20) {
                AXUIElementSetMessagingTimeout(child, ContextReader.messagingTimeout)
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// A node's contribution, if it has one.
    ///
    /// Requires both a label and a value: an unlabelled string is chrome as often
    /// as it is content, and without a name there is no way to tell the model what
    /// it is looking at. "Subject: Q3 audit" is worth a prompt line; a bare
    /// "Q3 audit" from an unidentified node is not.
    private func ambientField(of node: AXUIElement) -> TypingContext.AmbientField? {
        guard let role = string(node, attribute: kAXRoleAttribute) else { return nil }
        let textual = [kAXTextFieldRole, kAXStaticTextRole, kAXTextAreaRole]
            .map { $0 as String }
        guard textual.contains(role) else { return nil }

        guard let label = [kAXTitleAttribute, kAXDescriptionAttribute,
                           kAXPlaceholderValueAttribute]
            .lazy
            .compactMap({ self.string(node, attribute: $0) })
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }

        guard let raw = string(node, attribute: kAXValueAttribute) else { return nil }
        let value = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        return TypingContext.AmbientField(
            label: label.trimmingCharacters(in: .whitespaces),
            value: String(value.prefix(ContextReader.maxAmbientValueChars)))
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return nil }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let element = value else { return nil }
        // CFTypeRef -> AXUIElement is only safe once we know it really is one.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let focused = element as! AXUIElement

        // The timeout set in `init` applies to the system-wide element only. Every
        // query that actually matters — the value, the selection, the caret
        // geometry — goes to *this* element, which is a different AXUIElement and
        // therefore carries the framework default of six seconds.
        //
        // That default is the difference between a suggestion that fails to appear
        // and an app that cannot be typed in: five geometry attempts against a
        // beachballing app would hold the serial insertion queue for half a minute,
        // and every keystroke behind it. Capping it here is what makes a failure
        // cost 35ms and nothing else.
        AXUIElementSetMessagingTimeout(focused, ContextReader.messagingTimeout)
        return focused
    }

    /// The text either side of the caret.
    ///
    /// Both halves come from the one `kAXValue` fetch that was always being made:
    /// the previous version read the whole field and then discarded everything
    /// past the caret, which is why the app could not tell a half-typed word from
    /// a complete one. Keeping the far side costs nothing.
    private func accessibilityTextAroundCaret() -> (before: String, after: String)? {
        guard let element = focusedElement() else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }

        guard let range = selectedRange(of: element) else { return nil }

        // The AX range is in UTF-16 units; String indices are not.
        let utf16 = Array(text.utf16)
        let caret = min(max(0, range.location), utf16.count)
        let start = max(0, caret - ContextReader.maxContextChars)
        let end = min(utf16.count, caret + ContextReader.maxContextChars)
        guard caret >= start else { return nil }
        return (String(decoding: utf16[start..<caret], as: UTF16.self),
                String(decoding: utf16[caret..<end], as: UTF16.self))
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Caret geometry, for placing the ghost text

    /// Screen rect of the caret, in AppKit (bottom-left origin) coordinates.
    /// Falls back to the focused element's frame when the app will not answer
    /// the parameterized query, which many will not.
    public func caretRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        guard let range = selectedRange(of: element) else {
            return elementFrame(of: element).map(ContextReader.topLeftAnchor)
        }

        // Three ways to ask, because apps support different subsets. A zero-length
        // range is the precise question but many apps answer it with nothing; a
        // one-character range often works where the empty one does not; and the
        // caret's own line is the coarsest but most widely supported.
        let attempts: [CFRange] = [
            CFRange(location: range.location, length: 0),
            CFRange(location: max(0, range.location - 1), length: 1),
            CFRange(location: range.location, length: 1)
        ]
        for attempt in attempts {
            if let rect = bounds(of: element, for: attempt), rect.height > 0 {
                return ContextReader.flipToAppKit(rect)
            }
        }
        if let lineRect = boundsOfCaretLine(element) {
            return ContextReader.flipToAppKit(lineRect)
        }

        // Last resort: the element's own frame. Anchored to its TOP-left, not the
        // bottom — a chat composer is a tall box whose text starts at the top, so
        // the bottom-left corner is the furthest point from where you are typing,
        // which is exactly where the pill kept appearing.
        return elementFrame(of: element).map(ContextReader.topLeftAnchor)
    }

    private func bounds(of element: AXUIElement, for range: CFRange) -> CGRect? {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                value,
                &boundsRef) == .success,
              let raw = boundsRef, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        return rect.width >= 0 && rect.height > 0 ? rect : nil
    }

    /// Bounds of the line the caret sits on. Coarser than the caret itself, but
    /// it puts the pill on the right line, which is most of what matters.
    private func boundsOfCaretLine(_ element: AXUIElement) -> CGRect? {
        var lineRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXInsertionPointLineNumberAttribute as CFString, &lineRef) == .success,
              let line = lineRef as? Int else { return nil }

        // This parameterized attribute takes a plain CFNumber, not an AXValue.
        let lineValue = NSNumber(value: line) as CFTypeRef
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXRangeForLineParameterizedAttribute as CFString,
                lineValue,
                &rangeRef) == .success,
              let raw = rangeRef, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }

        var lineRange = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &lineRange) else { return nil }
        return bounds(of: element, for: lineRange)
    }

    private func elementFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = positionRef, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Accessibility reports screen coordinates with the origin at the top-left of
    /// the primary display; AppKit windows use bottom-left. Getting this backwards
    /// puts the overlay off-screen on multi-monitor setups rather than merely
    /// misaligned, which is why it is its own function.
    /// The element's top-left, as a caret-sized rect. Used when nothing will tell
    /// us where the caret actually is.
    private static func topLeftAnchor(_ frame: CGRect) -> CGRect {
        let topLeft = CGRect(x: frame.minX, y: frame.minY, width: 1, height: min(frame.height, 20))
        return flipToAppKit(topLeft)
    }

    /// The primary display, which is the one whose origin is (0, 0) — *not*
    /// simply the first in `NSScreen.screens`. Accessibility reports every screen
    /// coordinate relative to the primary's top-left, so getting this wrong put
    /// the pill a whole display away on multi-monitor setups.
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    private static func flipToAppKit(_ rect: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return rect }
        let flippedY = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    // MARK: - Word splitting

    /// Characters that count as part of a word. Unicode letters and digits cover
    /// Devanagari; combining marks matter because Devanagari matras are non-base
    /// characters and dropping them would split words mid-syllable.
    private static let wordCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.formUnion(.nonBaseCharacters)
        set.insert(charactersIn: "'")
        return set
    }()

    /// The partial word straddling the caret; empty if the caret follows a separator.
    public static func trailingWord(of text: String) -> String {
        var word = ""
        for scalar in text.unicodeScalars.reversed() {
            guard wordCharacters.contains(scalar) else { break }
            word.unicodeScalars.insert(scalar, at: word.unicodeScalars.startIndex)
        }
        return word
    }

    /// The partial word running forward from the start of `text`.
    ///
    /// The mirror of `trailingWord`: applied to the text after the caret it gives
    /// the tail of the word the caret is sitting inside, and an empty string when
    /// the caret is at a word boundary.
    public static func leadingWord(of text: String) -> String {
        var word = ""
        for scalar in text.unicodeScalars {
            guard wordCharacters.contains(scalar) else { break }
            word.unicodeScalars.append(scalar)
        }
        return word
    }

    public static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        wordCharacters.contains(scalar)
    }
}
