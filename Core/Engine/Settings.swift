import Foundation

/// User-facing preferences.
///
/// Learning and suggesting are separate switches on purpose. "Stop suggesting but
/// keep learning" is what you want in a meeting; "keep suggesting but stop
/// learning" is what you want when typing something you do not want remembered.
/// Collapsing them into one control would make both cases impossible.
public final class Settings {
    private enum Key {
        static let blockedApps = "TypeAhead.settings.blockedApps"
        static let learningPaused = "TypeAhead.settings.learningPaused"
        static let suggestionsEnabled = "TypeAhead.settings.suggestionsEnabled"
        static let inlineEnabled = "TypeAhead.settings.inlineEnabled"
    }

    /// Apps never observed and never suggested in, regardless of settings.
    /// Password managers and keychains handle secrets that macOS does not always
    /// mark as secure input, so they are excluded by default rather than left to
    /// the user to remember.
    public static let alwaysBlocked: Set<String> = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.apple.Passwords"
    ]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var blockedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.blockedApps) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.blockedApps) }
    }

    public var isLearningPaused: Bool {
        get { defaults.bool(forKey: Key.learningPaused) }
        set { defaults.set(newValue, forKey: Key.learningPaused) }
    }

    /// Whether suggestions were on last time. Restored at launch so the switch
    /// survives a restart.
    public var suggestionsEnabled: Bool {
        get { defaults.object(forKey: Key.suggestionsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.suggestionsEnabled) }
    }

    /// Whether to try writing the suggestion into the text field before falling
    /// back to the floating pill.
    ///
    /// **Off by default.** Inline puts real text in the document before it has
    /// been accepted, and in practice it does not hold up: the apps people write
    /// in mostly revert or refuse the Accessibility write, so the attempt costs a
    /// round trip per keystroke and returns nothing. The pill is the supported
    /// presentation. This stays as an opt-in switch rather than being deleted
    /// because the inline machinery is still here and still verified by tests.
    public var inlineEnabled: Bool {
        get { defaults.object(forKey: Key.inlineEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.inlineEnabled) }
    }

    public func isBlocked(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Settings.alwaysBlocked.contains(bundleID) || blockedApps.contains(bundleID)
    }

    public func block(_ bundleID: String) {
        var current = blockedApps
        current.insert(bundleID)
        blockedApps = current
    }

    public func unblock(_ bundleID: String) {
        var current = blockedApps
        current.remove(bundleID)
        blockedApps = current
    }
}
