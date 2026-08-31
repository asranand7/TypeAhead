import Cocoa
import InputMethodKit

/// Bootstraps the input method server.
///
/// The connection name must match `InputMethodConnectionName` in Info.plist, and
/// the controller class name must match `InputMethodServerControllerClass`.
/// A mismatch in either fails silently — the input source appears in the menu,
/// gets selected, and simply never receives a keystroke.

let bundle = Bundle.main
let connectionName = bundle.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "TypeAhead_1_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: bundle.bundleIdentifier) else {
    NSLog("TypeAhead IM: could not start IMKServer named \(connectionName)")
    exit(1)
}

// Held for the process lifetime; releasing it tears down the connection.
let retainedServer = server
NSLog("TypeAhead IM: server started as \(connectionName)")

NSApplication.shared.run()
