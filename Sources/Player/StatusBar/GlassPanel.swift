import AppKit

/// A borderless, arrowless Liquid Glass panel that hangs under the menu bar item, like
/// macOS 26's own menu bar panels. It can become key without activating the app, so the
/// app you were using stays frontmost while Escape and Space still reach the panel.
final class GlassPanel: NSPanel {
    /// Concentric with the content: 16pt padding around 16pt-radius artwork and icon circles.
    static let cornerRadius: CGFloat = 32

    private let glass = NSGlassEffectView()
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua) // dark glass keeps white text legible on any wallpaper

        // AppKit glass blurs what's *behind* the window. SwiftUI's .glassEffect only samples
        // content inside the window, which in this otherwise empty panel looks opaque.
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView = content

        // Clip everything to the rounded shape, so the window's corners are truly empty
        // and its shadow follows the curve instead of a square box.
        let rounded = NSView()
        rounded.wantsLayer = true
        rounded.layer?.cornerRadius = Self.cornerRadius
        rounded.layer?.cornerCurve = .continuous
        rounded.layer?.masksToBounds = true
        glass.frame = rounded.bounds
        glass.autoresizingMask = [.width, .height]
        rounded.addSubview(glass)
        contentView = rounded
    }

    override var canBecomeKey: Bool { true }

    /// Takes the content out of the window while the panel is closed. SwiftUI keeps
    /// animating (e.g. a playing badge) and re-laying out views in a hidden window, which
    /// cost ~10% CPU for something nobody could see.
    func detachContent() {
        guard !isVisible, glass.contentView != nil else { return }
        glass.contentView = nil
    }

    func attachContent() {
        guard glass.contentView == nil else { return }
        content.frame = glass.bounds
        glass.contentView = content
        content.layoutSubtreeIfNeeded() // reports its current size before the panel is placed
    }

    /// A borderless window's shadow is computed from what's drawn, so redo it once the
    /// rounded content has rendered (it starts out invisible while fading in).
    func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }
}
