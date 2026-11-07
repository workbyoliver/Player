import AppKit
import Observation

/// UI state shared by the menu bar item and the panel.
@Observable
final class StatusItemState {
    var isHovering = false
    var isPanelOpen = false
    /// Shown briefly in place of the track after a scroll-wheel volume change.
    var volumeFeedback: Float?
}

/// Sizes shared by the menu bar content and the NSStatusItem length calculation.
enum StatusItemLayout {
    static let padding: CGFloat = 6
    static let thumbnail: CGFloat = 16
    static let spacing: CGFloat = 6
    static let maxTextWidth: CGFloat = 180
    static let font = NSFont.menuBarFont(ofSize: 0)

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func itemWidth(text: String?) -> CGFloat {
        guard let text else { return padding * 2 + thumbnail }
        return padding * 2 + thumbnail + spacing + min(textWidth(text), maxTextWidth)
    }
}

/// What the menu bar item shows: the equalizer and "Title — Artist", the volume overlay
/// after a scroll, or ♪ when nothing is playing.
///
/// Plain AppKit views rather than SwiftUI: on macOS 26+ the menu bar shows a snapshot of
/// the item that AppKit re-renders on every change, and re-laying out SwiftUI for each
/// equalizer step was most of that cost.
final class StatusItemContentView: NSView {
    struct Content: Equatable {
        /// nil when nothing is playing.
        var text: String?
        var isPlaying = false
        var palette = ArtworkPalette.neutral
        var volumeFeedback: Float?
        var isHovering = false
    }

    var content = Content() {
        didSet { if content != oldValue { update(textChanged: content.text != oldValue.text) } }
    }

    private let equalizer = EqualizerView()
    private let title = MarqueeLabel()
    private let symbol = NSImageView() // ♪ when idle, the speaker during the volume overlay
    private let levelBar = LevelBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.contentTintColor = .labelColor
        symbol.imageScaling = .scaleNone
        for view in [equalizer, title, symbol, levelBar] { addSubview(view) }
        update(textChanged: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks belong to the status button

    override func layout() {
        super.layout()
        typealias Layout = StatusItemLayout
        let slot = NSRect(x: Layout.padding, y: ((bounds.height - Layout.thumbnail) / 2).rounded(),
                          width: Layout.thumbnail, height: Layout.thumbnail)
        equalizer.frame = slot
        symbol.frame = slot
        let textX = slot.maxX + Layout.spacing
        let textWidth = content.text.map { min(Layout.textWidth($0), Layout.maxTextWidth) } ?? 0
        title.frame = NSRect(x: textX, y: 0, width: textWidth, height: bounds.height)
        levelBar.frame = NSRect(x: textX, y: ((bounds.height - 4) / 2).rounded(), width: textWidth, height: 4)
    }

    private func update(textChanged: Bool) {
        let hasTrack = content.text != nil
        let showsVolume = content.volumeFeedback != nil

        equalizer.isHidden = !hasTrack || showsVolume
        equalizer.palette = content.palette
        equalizer.isPlaying = hasTrack && content.isPlaying && !showsVolume
        equalizer.alphaValue = content.isPlaying ? 1 : 0.6

        title.isHidden = !hasTrack || showsVolume
        title.text = content.text ?? ""
        title.isDimmed = !content.isPlaying
        title.isScrolling = content.isHovering && !showsVolume

        levelBar.isHidden = !(hasTrack && showsVolume)
        levelBar.level = CGFloat(content.volumeFeedback ?? 0)

        symbol.isHidden = hasTrack && !showsVolume
        if let level = content.volumeFeedback {
            symbol.image = NSImage(systemSymbolName: "speaker.wave.3.fill", variableValue: Double(level), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        } else if !hasTrack {
            symbol.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }

        if textChanged { needsLayout = true }
    }
}

/// One line of text drawn directly: truncated with "…" normally, and scrolling in a loop
/// with faded edges while `isScrolling` (only if it doesn't fit).
///
/// Drawn rather than built from layers: the menu bar snapshot (renderInContext) ignores
/// layer masks, so the edge fade has to be drawn.
final class MarqueeLabel: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            textWidth = StatusItemLayout.textWidth(text)
            restart()
        }
    }

    var isScrolling = false {
        didSet { if isScrolling != oldValue { restart() } }
    }

    var isDimmed = false {
        didSet { if isDimmed != oldValue { needsDisplay = true } }
    }

    private let gap: CGFloat = 36
    private let speed: CGFloat = 32 // points per second
    private let startDelay: TimeInterval = 0.35
    private let framesPerSecond = 30.0 // every frame is re-snapshotted, so not the display's full rate

    private var textWidth: CGFloat = 0
    private var offset: CGFloat = 0
    private var scrollStart = Date()
    private var timer: Timer?
    private var fadeMask: CGImage?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            fadeMask = nil
            restart()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = StatusItemLayout.font
        let color = NSColor.labelColor.withAlphaComponent(isDimmed ? 0.55 : 1)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let y = ((bounds.height - lineHeight) / 2).rounded()

        if timer != nil, let context = NSGraphicsContext.current?.cgContext, let mask = fadeMaskImage() {
            context.saveGState()
            context.clip(to: bounds, mask: mask)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            for x in [-offset, -offset + textWidth + gap] {
                (text as NSString).draw(
                    with: NSRect(x: x, y: y, width: textWidth + 4, height: lineHeight),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes
                )
            }
            context.restoreGState()
        } else {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(
                with: NSRect(x: 0, y: y, width: bounds.width, height: lineHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
            )
        }
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        offset = 0
        if isScrolling, textWidth > bounds.width + 0.5 {
            scrollStart = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() } // scheduled on the main run loop
            }
        }
        needsDisplay = true
    }

    private func step() {
        let elapsed = max(0, Date().timeIntervalSince(scrollStart) - startDelay)
        offset = (CGFloat(elapsed) * speed).truncatingRemainder(dividingBy: textWidth + gap)
        needsDisplay = true
    }

    /// Opaque in the middle, fading to clear over the outer 6% at each end.
    private func fadeMaskImage() -> CGImage? {
        if let fadeMask { return fadeMask }
        let width = max(Int(bounds.width * 2), 2)
        guard let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                        colorComponents: [0, 1, 1, 1, 1, 1, 0, 1], locations: [0, 0.06, 0.94, 1], count: 4)
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        fadeMask = context.makeImage()
        return fadeMask
    }
}

/// The volume overlay's level bar: a faint track with a filled portion.
final class LevelBar: NSView {
    var level: CGFloat = 0 {
        didSet { if level != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        var filled = bounds
        filled.size.width = bounds.width * min(max(level, 0), 1)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
