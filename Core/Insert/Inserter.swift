import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Puts accepted text into whatever the user is typing in.
///
/// Synthesised key events carrying a Unicode payload are the primary route: they
/// need no keycode mapping, so Devanagari and emoji work exactly as ASCII does,
/// and they land in apps that expose nothing to Accessibility.
///
/// Deliberately *not* clipboard-and-paste. Paste is the most reliable trick
/// available, but it destroys whatever the user had copied, and a typing aid that
/// silently eats your clipboard is not worth the reliability.
public final class Inserter {
    /// Stamped onto every event this app posts, so the tap can recognise its own
    /// synthetic keystrokes and not treat them as the user typing. Without it the
    /// app learns from its own suggestions and inflates its statistics.
    public static let syntheticEventMarker: Int64 = 0x54_59_50_45  // "TYPE"

    /// `keyboardSetUnicodeString` is not meant for unbounded strings; long
    /// payloads get truncated or dropped by some apps. Chunking keeps each event
    /// small enough to be delivered intact.
    private static let chunkSize = 16

    public init() {}

    /// Inserts `text`, first deleting `replacingPrevious` characters before the
    /// caret. The deletion is synthesised as backspaces rather than an
    /// Accessibility range edit, because backspaces work in every app — including
    /// the ones that expose nothing to Accessibility, which are exactly the apps
    /// where a correction is hardest to make by hand.
    public func insert(_ text: String, replacingPrevious: Int = 0) {
        guard !text.isEmpty || replacingPrevious > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        if replacingPrevious > 0 {
            for _ in 0..<replacingPrevious {
                guard let down = CGEvent(keyboardEventSource: source,
                                         virtualKey: CGKeyCode(kVK_Delete),
                                         keyDown: true),
                      let up = CGEvent(keyboardEventSource: source,
                                       virtualKey: CGKeyCode(kVK_Delete),
                                       keyDown: false)
                else { continue }
                down.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)
                up.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }

        guard !text.isEmpty else { return }

        for chunk in Inserter.chunks(of: text) {
            var utf16 = Array(chunk.utf16)

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)

            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Selects the `count` characters before the caret, by sending Shift+Left.
    ///
    /// The universal half of the inline ghost: no Accessibility involved, so it
    /// works in apps that expose nothing — browsers, terminals, anything that
    /// accepts a keystroke.
    public func selectPreviousCharacters(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            sendKey(CGKeyCode(kVK_LeftArrow), flags: .maskShift, source: source)
        }
    }

    /// Collapses a selection forwards, leaving the caret after the selected text.
    public func collapseSelectionForward() {
        sendKey(CGKeyCode(kVK_RightArrow), flags: [],
                source: CGEventSource(stateID: .combinedSessionState))
    }

    /// Deletes exactly `count` characters before the caret.
    ///
    /// Used to take back a typed ghost. Correct only because the ghost is always
    /// the tail of the field and the caller has just confirmed that by reading the
    /// text back — otherwise this would eat whatever happened to be there.
    public func deletePreviousCharacters(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            sendKey(CGKeyCode(kVK_Delete), flags: [], source: source)
        }
    }

    /// Deletes the current selection.
    public func deleteSelection() {
        sendKey(CGKeyCode(kVK_Delete), flags: [],
                source: CGEventSource(stateID: .combinedSessionState))
    }

    /// Re-sends a key the app never saw, because it was swallowed to clean up a
    /// ghost first. Ordering matters: CGEvent delivery is asynchronous, so letting
    /// the original key through and posting the deletion afterwards would race —
    /// and losing that race in a chat box means sending the suggestion.
    public func resend(keyCode: Int64, flags: CGEventFlags) {
        sendKey(CGKeyCode(keyCode), flags: flags,
                source: CGEventSource(stateID: .combinedSessionState))
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Inserter.syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= chunkSize {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
