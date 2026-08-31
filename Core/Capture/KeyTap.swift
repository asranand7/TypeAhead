import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// A single keystroke, as much of it as the predictor cares about.
public struct KeyEvent: Sendable, Equatable {
    public let keyCode: Int64
    public let characters: String
    public let modifiers: CGEventFlags

    public init(keyCode: Int64, characters: String, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    public var isTab: Bool { keyCode == kVK_Tab }
    public var isEscape: Bool { keyCode == kVK_Escape }
    public var isBackspace: Bool { keyCode == kVK_Delete }
    public var isReturn: Bool { keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter }
    public var isArrow: Bool {
        [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(keyCode))
    }
    public var isRightArrow: Bool { keyCode == kVK_RightArrow }
    public var isLeftArrow: Bool { keyCode == kVK_LeftArrow }

    /// The only two keys that accept a pending suggestion: Tab and left arrow.
    ///
    /// Everything else — right arrow included — passes through and dismisses,
    /// leaving the text exactly as typed. Right arrow was an accept key briefly
    /// and was wrong for it: with the ghost selected, every ordinary press of
    /// right arrow to nudge the caret would have taken a suggestion instead.
    ///
    /// With nothing pending both keys do their ordinary job, so Tab still indents
    /// and left arrow still moves the caret.
    public var isAcceptKey: Bool { isTab || isLeftArrow }

    /// Command/Control/Option chords are the user driving the app, not composing
    /// text. Shift is excluded from this test because shift is how you capitalise.
    public var isCommandChord: Bool {
        modifiers.contains(.maskCommand)
            || modifiers.contains(.maskControl)
            || modifiers.contains(.maskAlternate)
    }
}

public protocol KeyTapDelegate: AnyObject {
    /// Return true to swallow the event so the focused app never sees it.
    /// Swallowing is reserved for Tab while a suggestion is on screen — see the
    /// Tab-passthrough rule in the plan.
    func keyTap(_ tap: KeyTap, shouldSwallow event: KeyEvent) -> Bool

    /// Keystrokes were missed and the stream is no longer continuous.
    ///
    /// Happens when macOS disables a slow tap, and whenever secure input is
    /// switched on for a password field. Either way some characters reached the
    /// app without reaching us, so any word being accumulated has a hole in it and
    /// must be abandoned rather than completed with whatever arrives next.
    func keyTapDidLoseEvents(_ tap: KeyTap)
}

/// The global keystroke listener.
///
/// Runs a `CGEventTap` on the main run loop. The callback is on the hot path of
/// every keystroke on the machine, so it does no work beyond a secure-input check
/// and a delegate call; anything slower (Accessibility reads, prediction) is the
/// delegate's job to defer.
public final class KeyTap {
    public weak var delegate: KeyTapDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// True while keystrokes are being dropped, so the resumption can be reported
    /// exactly once rather than on every suppressed key.
    private var isDroppingEvents = false

    public init() {}

    /// True when the app already holds the Accessibility permission.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for Accessibility permission, showing the system prompt.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public var isRunning: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        guard KeyTap.isTrusted else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        runLoopSource = nil
        tap = nil
    }

    /// The system disables a tap that takes too long, or on certain user input.
    /// Without this the app dies silently after one slow moment.
    fileprivate func reenable() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        // Whatever the user typed while the tap was off went straight to the app.
        // Announcing the gap is what stops the word before it being glued to the
        // word after it.
        noteLostEvents()
    }

    private func noteLostEvents() {
        guard !isDroppingEvents else { return }
        isDroppingEvents = true
        delegate?.keyTapDidLoseEvents(self)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        // Nothing is read or stored while a password field is focused. Those
        // keystrokes still reach the app, so this is a gap in the stream like any
        // other and has to be reported as one.
        guard !SecureInputGuard.isActive else {
            noteLostEvents()
            return false
        }
        isDroppingEvents = false
        // Our own accepted-suggestion keystrokes come back through this tap.
        // Treating them as user input would make the app learn from itself.
        guard event.getIntegerValueField(.eventSourceUserData) != Inserter.syntheticEventMarker
        else { return false }
        guard let delegate else { return false }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        let characters = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""

        let key = KeyEvent(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            characters: characters,
            modifiers: event.flags
        )
        return delegate.keyTap(self, shouldSwallow: key)
    }
}

private func keyTapCallback(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }

    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
