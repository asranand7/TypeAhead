import Carbon
import Foundation

/// Registers and enables the TypeAhead input source.
///
/// Uses the Text Input Sources API — the same calls the "+" button in System
/// Settings makes. The alternative, writing `AppleEnabledInputSources` in
/// com.apple.HIToolbox by hand, is a well-known way to corrupt keyboard input
/// entirely, because the text input system caches that state and a malformed
/// entry is not validated.
///
/// Enables only. Selecting it — actually switching your keyboard to it — stays a
/// deliberate act, done from the input menu.

let bundleID = "com.typeahead.inputmethod.TypeAhead"
let path = NSHomeDirectory() + "/Library/Input Methods/TypeAheadIM.app"

guard FileManager.default.fileExists(atPath: path) else {
    print("❌ Not installed at \(path) — run ./build-im.sh first.")
    exit(1)
}

// Registration makes the system aware of a bundle dropped into Input Methods
// without waiting for a login cycle.
let registerStatus = TISRegisterInputSource(URL(fileURLWithPath: path) as CFURL)
if registerStatus != noErr && registerStatus != paramErr {
    print("⚠️  TISRegisterInputSource returned \(registerStatus) (often harmless if already known)")
}

// includeAllInstalled: true is essential — a source that is merely installed and
// not yet enabled is invisible to the default listing, which is exactly the state
// we are trying to change.
let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
      !list.isEmpty else {
    print("❌ The system does not yet see the input source.")
    print("   This usually means the bundle's Info.plist is malformed, or macOS")
    print("   has not rescanned. Log out and back in, then run this again.")
    exit(1)
}

var enabled = 0
for source in list {
    let name = unsafeBitCast(TISGetInputSourceProperty(source, kTISPropertyLocalizedName),
                             to: CFString?.self) as String? ?? "?"
    let id = unsafeBitCast(TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                           to: CFString?.self) as String? ?? "?"

    let status = TISEnableInputSource(source)
    if status == noErr {
        print("✅ Enabled: \(name)  [\(id)]")
        enabled += 1
    } else {
        print("❌ Could not enable \(name): OSStatus \(status)")
    }
}

if enabled > 0 {
    print("")
    print("Now pick TypeAhead from the input menu in your menu bar (⌃Space cycles).")
    print("Suggestions will appear inside the text field. Tab accepts.")
}
exit(enabled > 0 ? 0 : 1)
