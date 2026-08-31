import Cocoa

/// The floating panel that shows the pending suggestion.
///
/// Borderless, non-activating, status-bar level, joins all spaces, ignores mouse
/// events. Those five properties together are what let a window hover over
/// another app's text field without stealing focus mid-keystroke — and, just as
/// importantly, without ever being something the writer has to get out of the way
/// of. It cannot be clicked, focused, dragged or closed, because it is not a
/// window in any sense the user should have to think about. It is a label that
/// happens to float.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // A shadow, unlike the first version of this panel. The rule it was
        // avoiding — an offer must not read as text the app already typed — is
        // enforced by the pill sitting *outside* the field entirely. Within that,
        // the shadow is what lifts the chip off whatever it floats over; without
        // one it is unreadable against anything but a plain background.
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        // AppKit's own window fades fight the ones below and leave the panel
        // visible after `orderOut` on a fast typist.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The rounded key-cap drawn after the suggestion.
///
/// A bare glyph reads as punctuation belonging to the suggestion — "regards,
/// Anand ⇥" looks like the arrow is part of what would be inserted. Drawn as a
/// key it reads as an instruction instead, which is what it is: the one key that
/// takes the offer, and the only key this app ever consumes.
private final class KeyCapView: NSView {
    override var isFlipped: Bool { true }

    static let size = CGSize(width: 20, height: 16)

    private let glyph = "\u{21E5}" as NSString
    private let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 4.5, yRadius: 4.5)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55)
        ]
        let glyphSize = glyph.size(withAttributes: attributes)
        glyph.draw(at: NSPoint(x: (bounds.width - glyphSize.width) / 2,
                               y: (bounds.height - glyphSize.height) / 2),
                   withAttributes: attributes)
    }
}

/// A semi-opaque wash laid over the vibrancy.
///
/// `NSVisualEffectView` alone is too transparent for this job. The pill floats
/// over arbitrary content — code, a photo, another paragraph — and pure vibrancy
/// lets that content through at a contrast that competes with the suggestion
/// itself, so the text underneath and the text on top are read at once and
/// neither wins. The wash keeps enough of the blur to feel like a system chip
/// while making the label the only thing you actually read.
private final class TintView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        dirtyRect.fill()
    }
}

public final class SuggestionOverlay {
    /// Gap between the top of the caret and the bottom of the pill. Big enough
    /// that the descenders of the line above do not touch the chip.
    static let caretGap: CGFloat = 8
    static let paddingLeading: CGFloat = 11
    static let paddingTrailing: CGFloat = 8
    static let paddingVertical: CGFloat = 5
    static let labelToKeyCap: CGFloat = 8
    /// Past this the pill stops growing and the text truncates. A pill wider than
    /// this has stopped being something you glance at and become a banner parked
    /// over your document.
    static let maxWidth: CGFloat = 420

    private var panel: OverlayPanel?
    private let label = NSTextField(labelWithString: "")
    private let keyCap = KeyCapView(frame: .zero)
    private let tint = TintView(frame: .zero)

    /// Set while a fade-out is in flight, so its completion cannot order out a
    /// panel that a newer `show` has already brought back.
    private var fadeOutToken = 0

    public init() {}

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Showing

    public func show(text: String, at caret: CGRect?) {
        let display = SuggestionOverlay.singleLine(text)
        guard !display.isEmpty else { hide(); return }

        let panel = ensurePanel()
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        fadeOutToken &+= 1

        label.stringValue = display
        label.sizeToFit()

        let maxLabelWidth = SuggestionOverlay.maxWidth
            - KeyCapView.size.width
            - SuggestionOverlay.labelToKeyCap
            - SuggestionOverlay.paddingLeading
            - SuggestionOverlay.paddingTrailing
        label.frame.size.width = max(0, min(label.frame.width, maxLabelWidth))

        let size = CGSize(
            width: SuggestionOverlay.paddingLeading + label.frame.width
                + SuggestionOverlay.labelToKeyCap + KeyCapView.size.width
                + SuggestionOverlay.paddingTrailing,
            height: max(label.frame.height, KeyCapView.size.height)
                + SuggestionOverlay.paddingVertical * 2)

        label.frame.origin = CGPoint(x: SuggestionOverlay.paddingLeading,
                                     y: (size.height - label.frame.height) / 2)
        keyCap.frame = CGRect(
            x: SuggestionOverlay.paddingLeading + label.frame.width
                + SuggestionOverlay.labelToKeyCap,
            y: (size.height - KeyCapView.size.height) / 2,
            width: KeyCapView.size.width,
            height: KeyCapView.size.height)
        keyCap.needsDisplay = true

        let origin = SuggestionOverlay.position(for: caret, size: size)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        // Radius tracks the height, so the chip stays a true capsule instead of
        // becoming a rounded rectangle whenever the system font size changes.
        (panel.contentView as? NSVisualEffectView)?.layer?.cornerRadius = size.height / 2
        panel.invalidateShadow()

        guard !wasVisible, !SuggestionOverlay.reduceMotion else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        // Appears by rising a couple of points into place. Short enough not to
        // lag a keystroke, long enough that the chip does not simply blink into
        // existence in the corner of your eye while you are reading.
        panel.alphaValue = 0
        panel.setFrameOrigin(CGPoint(x: origin.x, y: origin.y - 3))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
    }

    // MARK: - Hiding

    public func hide() {
        guard let panel, panel.isVisible else { return }

        guard !SuggestionOverlay.reduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        fadeOutToken &+= 1
        let token = fadeOutToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.07
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            // A `show` during the fade bumps the token. Without this check its
            // freshly raised pill would be ordered out by the old animation.
            guard let self, self.fadeOutToken == token else { return }
            panel?.orderOut(nil)
        })
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Text

    /// Newlines and runs of whitespace collapse to single spaces.
    ///
    /// A mined snippet can be several lines long. Rendered literally it is either
    /// clipped to its first line or inflates the pill to the size of a paragraph,
    /// and a suggestion that covers the document is worse than no suggestion.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    // MARK: - Placement

    /// Sits **above** the caret, left edge aligned with it.
    ///
    /// Above rather than beside. To the right of the caret is precisely where the
    /// next character is about to go, so a pill there covers the word as you type
    /// it and jitters sideways on every keystroke. One line up it is stationary
    /// while you finish the word, it never occludes what you are currently
    /// writing, and your eye is already on that line.
    ///
    /// Left-aligned rather than centred, so the suggestion starts roughly where
    /// the text would and reads as a continuation of the sentence rather than as
    /// a tooltip about it.
    ///
    /// Flips below the caret when there is no room above — the first line of a
    /// window near the top of the display — and is clamped to the screen so a
    /// caret near an edge does not push the chip off it.
    static func position(for caret: CGRect?, size: CGSize) -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let caret else {
            let visible = screen?.visibleFrame ?? .zero
            return CGPoint(x: visible.midX - size.width / 2, y: visible.midY)
        }

        // The label starts at `paddingLeading`; backing that out lines the first
        // glyph of the suggestion up with the caret rather than the chip's edge.
        var x = caret.minX - SuggestionOverlay.paddingLeading
        var y = caret.maxY + SuggestionOverlay.caretGap

        guard let frame = (NSScreen.screens.first { $0.frame.intersects(caret) }
                            ?? screen)?.visibleFrame else {
            return CGPoint(x: x, y: y)
        }

        // No room above: go below the caret rather than let the clamp slide the
        // chip down *onto* the line being typed.
        if y + size.height > frame.maxY - 4 {
            y = caret.minY - SuggestionOverlay.caretGap - size.height
        }
        y = min(max(y, frame.minY + 4), frame.maxY - size.height - 4)

        x = min(x, frame.maxX - size.width - 4)
        x = max(x, frame.minX + 4)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Construction

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }

        let created = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26))
        let content = NSVisualEffectView(frame: created.contentView?.bounds ?? .zero)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 13
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]

        // Legible, but not as legible as the writer's own text. The suggestion is
        // not text yet — it is an offer. Rendering it at full contrast would read
        // as something the app had already typed for you, which is exactly the
        // anxiety rule 1 exists to prevent.
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.72)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true

        // Order matters: the wash goes down first, then the content on top of it.
        tint.frame = content.bounds
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)
        content.addSubview(label)
        content.addSubview(keyCap)
        created.contentView = content

        panel = created
        return created
    }
}
