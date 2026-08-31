import Cocoa

/// Supplies menu entries. Later phases — the model picker, the memory review
/// window, the app blocklist — conform to this and are handed to the controller,
/// rather than each one editing the menu construction in place.
public protocol MenuContributor: AnyObject {
    var menuTitle: String { get }
    func makeMenuItems() -> [NSMenuItem]
}

/// The menu bar presence: the on/off switch and the keystrokes-saved readout.
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let coordinator: Coordinator
    private let savings: SavingsCounter
    private var contributors: [MenuContributor] = []

    /// Opens the settings window. A menu is fine for a switch and a few actions,
    /// but comparing models or managing a blocklist needs a window.
    public var onOpenSettings: (() -> Void)?

    public init(coordinator: Coordinator, savings: SavingsCounter) {
        self.coordinator = coordinator
        self.savings = savings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        coordinator.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }
        render()
    }

    public func add(_ contributor: MenuContributor) {
        contributors.append(contributor)
        render()
    }

    /// Rebuilds the menu after something a contributor owns has changed.
    public func refresh() {
        render()
    }

    private func render() {
        if let button = statusItem.button {
            // "text.cursor.slash" does not exist as an SF Symbol. Asking for it
            // returned nil, leaving a button with no image and no title — an
            // invisible menu bar item, and no way to switch the app back on.
            let symbol = coordinator.isEnabled ? "keyboard.fill" : "keyboard"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TypeAhead")
            image?.isTemplate = true
            button.image = image
            // Never let the item render as nothing, whatever happens to symbols.
            button.title = image == nil ? "TA" : ""
            button.toolTip = coordinator.isEnabled
                ? "TypeAhead — suggestions on"
                : "TypeAhead — suggestions off"
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: coordinator.isEnabled ? "Suggestions On" : "Suggestions Off",
            action: #selector(toggleEnabled),
            keyEquivalent: "")
        toggle.target = self
        toggle.state = coordinator.isEnabled ? .on : .off
        menu.addItem(toggle)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let launch = NSMenuItem(title: "Start at login",
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        // The headline metric, in front of the user rather than buried in a report.
        let saved = NSMenuItem(
            title: "\(savings.totalKeystrokesSaved) keystrokes saved",
            action: nil,
            keyEquivalent: "")
        saved.isEnabled = false
        menu.addItem(saved)

        let session = NSMenuItem(
            title: "\(savings.sessionKeystrokesSaved) this session",
            action: nil,
            keyEquivalent: "")
        session.isEnabled = false
        menu.addItem(session)

        for contributor in contributors {
            menu.addItem(.separator())
            let header = NSMenuItem(title: contributor.menuTitle, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in contributor.makeMenuItems() {
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TypeAhead",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleEnabled() {
        coordinator.toggle()
        render()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func toggleLaunchAtLogin() {
        let wanted = !LaunchAtLogin.isEnabled
        // Remembered so the self-healing path never argues with a deliberate no.
        LaunchAtLogin.noteUserChoice(wanted)
        if !LaunchAtLogin.setEnabled(wanted) {
            MemoryMenu.inform(
                "Login item is managed in System Settings",
                "Open System Settings › General › Login Items and enable TypeAhead there.")
        }
        render()
    }

    /// Shown when the app starts without Accessibility permission, which is the
    /// one failure the user has to fix themselves.
    public func presentPermissionPrompt() {
        let alert = NSAlert()
        alert.messageText = "TypeAhead needs Accessibility access"
        alert.informativeText = """
            Suggestions require permission to read the text field you are typing in \
            and to insert accepted text.

            Open System Settings › Privacy & Security › Accessibility and enable \
            TypeAhead, then choose Suggestions On from the menu bar.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            KeyTap.requestTrust()
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
