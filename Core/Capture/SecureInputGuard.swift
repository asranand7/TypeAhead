import Carbon.HIToolbox
import Foundation

/// Detects macOS secure input, which is what a password field turns on.
///
/// While secure input is active the app must read nothing and store nothing.
/// This is checked on the hot path of every keystroke rather than at focus
/// changes, because secure input can be enabled by an app at any moment and a
/// stale answer here would mean logging a password.
public enum SecureInputGuard {
    public static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
