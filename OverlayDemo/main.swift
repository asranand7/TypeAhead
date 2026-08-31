import Cocoa
import TypeAheadCore

/// Shows the suggestion overlay on its own, with no event tap and no store.
///
/// Exists so the display path can be verified in isolation. "I see no
/// suggestions" has three very different causes — nothing learned, learned but
/// gated, or suggesting fine but invisible — and this rules the third in or out
/// without needing the first two to be true.
///
///     swift run typeahead-overlay-demo [seconds]

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 4.0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Demo: NSObject, NSApplicationDelegate {
    let overlay = SuggestionOverlay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { exit(1) }

        // Three shapes the real overlay has to render, laid out where a caret
        // plausibly is, so placement and clamping get exercised too.
        let samples: [(String, CGRect)] = [
            ("hary", CGRect(x: screen.frame.midX - 260, y: screen.frame.midY + 80, width: 2, height: 18)),
            ("regards, Anand", CGRect(x: screen.frame.midX - 260, y: screen.frame.midY + 20, width: 2, height: 18)),
            ("me know if that works", CGRect(x: screen.frame.midX - 260, y: screen.frame.midY - 40, width: 2, height: 18))
        ]

        var panels: [SuggestionOverlay] = []
        for (text, caret) in samples {
            let panel = SuggestionOverlay()
            panel.show(text: text, at: caret)
            panels.append(panel)
        }
        self.extra = panels

        print("Overlay shown for \(seconds)s at \(screen.frame.midX - 260), \(screen.frame.midY)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.terminate(nil)
        }
    }

    var extra: [SuggestionOverlay] = []
}

let delegate = Demo()
app.delegate = delegate
app.run()
