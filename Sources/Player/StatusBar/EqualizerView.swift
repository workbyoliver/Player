import AppKit

/// The menu bar's four-bar equalizer in the artwork's colours: steps while playing,
/// rests as short bars when paused.
///
/// Plain layers rather than SwiftUI: on macOS 26+ AppKit re-snapshots a menu bar item
/// whenever it changes, and re-rendering the SwiftUI content on every step cost ~16% CPU.
/// Moving four layers is all a step needs here. Stepped (no in-between
/// frames), 6 per second, for the same reason: each step costs a few ms of snapshotting.
final class EqualizerView: NSView {
    var palette: ArtworkPalette = .neutral {
        didSet { if palette != oldValue { applyColors() } }
    }

    var isPlaying = false {
        didSet { if isPlaying != oldValue { restartTimer() } }
    }

    private static let barCount = 4
    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 1.5
    private static let maxHeight: CGFloat = 12
    private static let restHeight: CGFloat = 3
    private static let stepsPerSecond = 6.0

    private let bars = (0..<EqualizerView.barCount).map { _ in CALayer() }
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    // The bars are sublayers, so there's nothing to draw. Opting into updateLayer keeps
    // `needsDisplay` (which prompts AppKit to refresh the menu bar's snapshot) from
    // rebuilding an empty backing store, and waiting on the render server, every step.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks belong to the status button

    override func layout() {
        super.layout()
        placeBars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors() // light vs dark menu bar
    }

    // MARK: - Private

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        if isPlaying {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.stepsPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeBars() } // scheduled on the main run loop
            }
        }
        placeBars()
    }

    private func placeBars() {
        let time = Date.timeIntervalSinceReferenceDate
        let totalWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.spacing
        var x = ((bounds.width - totalWidth) / 2).rounded()
        let bottom = ((bounds.height - Self.maxHeight) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true) // jump, don't animate: the snapshot can't show animations
        for (index, bar) in bars.enumerated() {
            let height = isPlaying ? Self.height(of: index, at: time) : Self.restHeight
            bar.frame = CGRect(x: x, y: bottom, width: Self.barWidth, height: height.rounded())
            x += Self.barWidth + Self.spacing
        }
        CATransaction.commit()
        needsDisplay = true // tells AppKit to refresh the menu bar's snapshot of the item
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colors = palette == .neutral
                ? Array(repeating: NSColor.labelColor, count: Self.barCount)
                : palette.accentColors(count: Self.barCount, forDarkBackground: isDark)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (bar, color) in zip(bars, colors) { bar.backgroundColor = color.cgColor }
            CATransaction.commit()
        }
        needsDisplay = true
    }

    /// Two sine waves per bar at unrelated speeds, so the pattern never visibly repeats.
    private static func height(of bar: Int, at time: TimeInterval) -> CGFloat {
        let speeds: [(Double, Double)] = [(5.1, 7.9), (6.3, 4.4), (4.7, 8.6), (7.2, 5.3)]
        let (a, b) = speeds[bar % speeds.count]
        let phase = Double(bar) * 1.7
        let level = abs(sin(time * a + phase) * 0.6 + sin(time * b + phase * 2.3) * 0.4)
        return restHeight + (maxHeight - restHeight) * CGFloat(level)
    }
}
