import Cocoa
import TypeAheadCore

// Menu-bar only: no Dock icon, no main window. LSUIElement in Info.plist says the
// same thing, and both are needed — the plist for launch, this for the case where
// the binary is run directly during development.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = TypeAheadApp()
application.delegate = delegate
application.run()
