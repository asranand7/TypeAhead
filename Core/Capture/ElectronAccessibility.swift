import ApplicationServices
import Cocoa

/// Wakes up the accessibility tree in Chromium-based apps.
///
/// Electron apps — Claude, Slack, VS Code, Discord, Notion — do not expose their
/// text fields to Accessibility by default. Chromium builds that tree lazily and
/// only when an assistive technology asks for it, because maintaining it is
/// expensive. Until something asks, the focused element has no value, no selected
/// text, and nothing to write into, so both the context read and the inline ghost
/// come back empty.
///
/// The ask is a single undocumented-but-longstanding attribute,
/// `AXManualAccessibility`, set on the *application* element. Screen readers set
/// it; so does anything else that needs Chromium's tree.
///
/// Harmless on non-Chromium apps: they simply do not support the attribute and
/// the write fails silently, so this can be applied to every app without
/// discrimination.
public enum ElectronAccessibility {
    /// Two attributes, because Chromium has used both over time and which one
    /// works depends on the Electron version an app happens to ship.
    /// `AXManualAccessibility` is the modern one; `AXEnhancedUserInterface` is
    /// what older builds (and some other toolkits) watch for. Setting both is
    /// harmless and avoids guessing at an app's Electron version.
    private static let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    /// Diagnostic log of what each app actually exposed, so "it does not work in
    /// app X" can be answered with evidence instead of a theory.
    public static let logPath = NSHomeDirectory()
        + "/Library/Application Support/TypeAhead/accessibility.log"

    /// Apps already asked, so a focus change does not repeat the work. Keyed by
    /// pid: a relaunched app gets a new one and is asked again, which is correct.
    private static var enabled = Set<pid_t>()
    private static let lock = NSLock()

    @discardableResult
    public static func enable(for pid: pid_t) -> Bool {
        lock.lock()
        if enabled.contains(pid) {
            lock.unlock()
            return true
        }
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        var anySucceeded = false
        for name in attributes {
            let status = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
            if status == .success { anySucceeded = true }
        }

        // Wait regardless of what the writes returned. Chrome reports failure for
        // both attributes and yet still responds to them, so gating the wait on
        // the status code meant Chrome never got the moment it needed to build its
        // tree. The status is not evidence either way; only reading the element is.
        Thread.sleep(forTimeInterval: 0.15)

        report(pid: pid, asked: anySucceeded)

        // Recorded even on failure: a non-Chromium app will never support this,
        // and retrying on every keystroke would be pure waste.
        lock.lock()
        enabled.insert(pid)
        lock.unlock()

        return anySucceeded
    }

    /// Writes what this app exposes to a log file.
    ///
    /// The app is the only process here holding Accessibility permission, so it is
    /// the only one that can answer "does app X expose a writable text field".
    /// A separate probe always reports API-disabled and tells you nothing.
    private static func report(pid: pid_t, asked: Bool) {
        let running = NSRunningApplication(processIdentifier: pid)
        let name = running?.localizedName ?? "?"
        let bundle = running?.bundleIdentifier ?? "?"

        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused)

        var line = "[\(ISO8601DateFormatter().string(from: Date()))] \(name) [\(bundle)]"
        line += " asked=\(asked) focusStatus=\(focusStatus.rawValue)"

        if focusStatus == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = raw as! AXUIElement
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &settable)
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            line += " role=\((role as? String) ?? "?")"
            line += " attrs=\((names as? [String])?.count ?? 0)"
            line += " selectedTextWritable=\(settable.boolValue)"
            line += settable.boolValue ? "  → INLINE OK" : "  → falls back to pill"
        } else {
            line += "  → no focused element; falls back to pill"
        }

        line += "\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    /// Asks the frontmost app, whatever it is.
    ///
    /// Off the main thread: waking Chromium's tree includes a short wait for it to
    /// be built, and this is called from app-switch and click handlers that run on
    /// the main thread. Blocking there would stutter the UI on every app switch.
    public static func enableForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier

        lock.lock()
        let alreadyDone = enabled.contains(pid)
        lock.unlock()
        guard !alreadyDone else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            enable(for: pid)
        }
    }

    /// Forgets a process so it will be asked again — used when an app quits, so a
    /// relaunch under a recycled pid is not mistaken for one already handled.
    public static func forget(_ pid: pid_t) {
        lock.lock()
        enabled.remove(pid)
        lock.unlock()
    }
}
