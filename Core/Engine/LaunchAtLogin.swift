import Foundation
import ServiceManagement

/// Registers the app to start at login.
///
/// A typing aid that has to be launched by hand is a typing aid you stop using:
/// the value is entirely in it already being there when you start writing. So it
/// registers itself on first run and stays out of the way — a background agent
/// with no Dock icon and no window, which is what `LSUIElement` in the bundle
/// declares.
///
/// Still a switch, not a decision made for the user — it appears in the menu and
/// can be turned off.
public enum LaunchAtLogin {
    private static let hasRegisteredKey = "TypeAhead.launchAtLogin.configured"

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // .requiresApproval means the user disabled it in System Settings.
                // Re-registering would fight them, so treat it as their answer.
                guard SMAppService.mainApp.status != .requiresApproval else { return false }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// Set once the user has expressed an opinion, so we can tell "never turned
    /// on" apart from "deliberately turned off".
    private static let userChoiceKey = "TypeAhead.launchAtLogin.userChoice"

    /// Records that the user chose this state themselves, which stops the
    /// self-healing path below from ever overriding it.
    public static func noteUserChoice(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: userChoiceKey)
    }

    /// Registers at login on first run, and repairs a registration that did not
    /// take — without ever overriding a user who turned it off.
    ///
    /// The first version set a "configured" flag and returned early forever
    /// after. That flag records only that registration was *attempted*:
    /// `SMAppService.register()` fails for reasons that have nothing to do with
    /// the user's wishes — the app not yet in /Applications, a signature that
    /// changed since the last launch — and once the flag was set the app would
    /// never try again. The symptom is an app that quietly stops starting at
    /// login and offers no clue why.
    ///
    /// So the flag is now only consulted for the *first* attempt. After that,
    /// registration is re-attempted whenever the service reports itself
    /// unregistered and the user has not explicitly opted out. `requiresApproval`
    /// is left strictly alone: that state means the user disabled it in System
    /// Settings, and re-registering would be arguing with them.
    public static func configureOnFirstRun(defaults: UserDefaults = .standard) {
        let firstRun = !defaults.bool(forKey: hasRegisteredKey)
        if firstRun {
            defaults.set(true, forKey: hasRegisteredKey)
            setEnabled(true)
            return
        }

        // The user's own answer wins, in both directions.
        if let choice = defaults.object(forKey: userChoiceKey) as? Bool {
            guard choice else { return }
        }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        setEnabled(true)
    }
}
