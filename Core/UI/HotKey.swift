import Carbon.HIToolbox
import Cocoa

/// A global hotkey for the on/off switch.
///
/// Registered through Carbon rather than an `NSEvent` monitor because Carbon
/// hotkeys fire even when the app has no window and no focus — which is always,
/// for a menu-bar app. The point is being able to kill suggestions instantly
/// mid-sentence without reaching for the menu bar.
public final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Default binding: Option-Shift-Space. Unclaimed by macOS and by the apps
    /// people type in, and reachable without moving your hands off the keys.
    public static let defaultKeyCode = UInt32(kVK_Space)
    public static let defaultModifiers = UInt32(optionKey | shiftKey)

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
    }

    @discardableResult
    public func register(keyCode: UInt32 = HotKey.defaultKeyCode,
                         modifiers: UInt32 = HotKey.defaultModifiers) -> Bool {
        unregister()

        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            HotKey.instances[hotKeyID.id]?.action()
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x54_59_50_45), id: id)  // "TYPE"
        return RegisterEventHotKey(keyCode,
                                   modifiers,
                                   hotKeyID,
                                   GetApplicationEventTarget(),
                                   0,
                                   &reference) == noErr
    }

    public func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}
