import SwiftUI

/// Sizes shared across the panel. The corner radius (GlassPanel) is padding + the artwork's
/// 16pt radius, so the corners stay concentric.
private enum PanelLayout {
    static let width: CGFloat = 264
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 14
    static var contentWidth: CGFloat { width - padding * 2 }
}

/// The panel: a colour flood from the album artwork over Liquid Glass, with the artwork,
/// track info, progress, transport, volume and sources on top.
struct NowPlayingPanelView: View {
    let nowPlaying: NowPlayingService
    let volume: VolumeService
    let appVolumes: AppVolumes
    let state: StatusItemState
    /// Reports the content size so the panel can stay pinned under the menu bar as it changes.
    let onSizeChange: (CGSize) -> Void

    private let shape = RoundedRectangle(cornerRadius: GlassPanel.cornerRadius, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.spacing) {
            if let track = nowPlaying.track {
                TrackSection(nowPlaying: nowPlaying, track: track, isVisible: state.isPanelOpen)
            } else {
                EmptyState(problem: nowPlaying.problem)
            }
            VolumeRow(nowPlaying: nowPlaying, volume: volume, appVolumes: appVolumes)
            if !nowPlaying.sources.isEmpty {
                SourceSwitcher(nowPlaying: nowPlaying)
            }
        }
        .padding(PanelLayout.padding)
        .frame(width: PanelLayout.width)
        .background {
            ColorFlood(
                palette: nowPlaying.palette,
                isVisible: state.isPanelOpen,
                isAnimating: state.isPanelOpen && nowPlaying.track?.isPlaying == true
            )
            .opacity(0.32) // a tint over the panel's glass (GlassPanel), which blurs what's behind
        }
        .clipShape(shape)
        .environment(\.colorScheme, .dark) // white text reads well on dark glass and any flood
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSizeChange)
    }
}

// MARK: - Track

private struct TrackSection: View {
    let nowPlaying: NowPlayingService
    let track: Track
    let isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.spacing) {
            Artwork(image: nowPlaying.artwork, fallbackIcon: nowPlaying.source?.icon)

            TrackTitle(
                title: track.title.isEmpty ? "Unknown title" : track.title,
                subtitle: [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
            )

            VStack(spacing: 8) {
                if let duration = track.duration {
                    Scrubber(track: track, duration: duration, isLive: isVisible && track.isPlaying) { seconds in
                        nowPlaying.seek(to: seconds)
                    }
                } else {
                    // Live streams have no duration; keep the space so the panel doesn't jump.
                    Scrubber(track: track, duration: 1, isLive: false) { _ in }.hidden()
                }
                transport
            }
            .disabled(!nowPlaying.canControl)
            .opacity(nowPlaying.canControl ? 1 : 0.4)
            .help(nowPlaying.canControl ? "" : uncontrollableHint)
        }
    }

    private var uncontrollableHint: String {
        let name = nowPlaying.selectedSource?.name ?? "this app"
        return "macOS only sends playback controls to the active player. Control \(name) from its own window, or start it playing to make it active."
    }

    private var transport: some View {
        HStack(spacing: 36) {
            TransportButton(symbol: "backward.fill", size: 16, label: "Previous") { nowPlaying.send(.prev) }
            TransportButton(
                symbol: track.isPlaying ? "pause.fill" : "play.fill",
                size: 24,
                label: track.isPlaying ? "Pause" : "Play"
            ) { nowPlaying.send(.toggle) }
            TransportButton(symbol: "forward.fill", size: 16, label: "Next") { nowPlaying.send(.next) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line each: the title (scrolls on hover when it doesn't fit) and "Artist — Album".
/// Always two lines tall, so changing track never resizes the panel.
private struct TrackTitle: View {
    let title: String
    let subtitle: String

    @State private var isHovering = false
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarqueeText(
                text: title,
                font: Self.titleFont,
                textWidth: ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width),
                maxWidth: PanelLayout.contentWidth,
                isScrolling: isHovering
            )
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(subtitle.isEmpty ? title : "\(title)\n\(subtitle)")
    }
}

/// Always square (video thumbnails are cropped to fill), so the panel keeps its size.
private struct Artwork: View {
    let image: NSImage?
    let fallbackIcon: NSImage?

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.clear
                    if let fallbackIcon {
                        Image(nsImage: fallbackIcon).resizable().frame(width: 72, height: 72)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 52)).foregroundStyle(.secondary)
                    }
                }
                .glassEffect(.regular, in: shape)
            }
        }
        .frame(width: PanelLayout.contentWidth, height: PanelLayout.contentWidth)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

/// A plain transport symbol: no chrome, a little lift on hover, a dip when pressed.
private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .opacity(isHovering ? 1 : 0.85)
        .scaleEffect(isHovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct PressDipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Elapsed · bar · remaining, on one line.
private struct Scrubber: View {
    let track: Track
    let duration: TimeInterval
    /// Tick only while the panel is open and playing; otherwise draw once.
    let isLive: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var dragPosition: TimeInterval?

    var body: some View {
        // Paused while the panel is closed or the track is paused.
        TimelineView(.animation(minimumInterval: 0.5, paused: !isLive)) { context in
            let position = dragPosition ?? track.elapsed(at: isLive ? context.date : track.timestamp)
            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(minWidth: 30, alignment: .leading)
                ThinSlider(
                    value: position / duration,
                    label: "Playback position",
                    valueDescription: "\(Self.format(position)) of \(Self.format(duration))",
                    step: 10 / duration, // VoiceOver steps 10 seconds (the whole track if shorter)
                    onChange: { dragPosition = $0 * duration },
                    onCommit: { fraction in
                        onSeek(fraction * duration)
                        dragPosition = nil
                    }
                )
                Text("-" + Self.format(duration - position))
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Volume and sources

/// Controls the selected app's own volume (see AppVolumes); with no app selected,
/// the Mac's output volume.
private struct VolumeRow: View {
    let nowPlaying: NowPlayingService
    let volume: VolumeService
    let appVolumes: AppVolumes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = nowPlaying.selectedSource {
                let level = appVolumes.level(for: source)
                row(level: level, isMuted: level == 0, label: "\(source.name) volume") {
                    appVolumes.setLevel($0, for: source)
                }
                .help("\(source.name) volume. Your keyboard's volume keys still set the Mac's.")
            } else if let level = volume.volume {
                row(level: volume.isMuted ? 0 : level, isMuted: volume.isMuted, label: "Volume") {
                    volume.setVolume($0)
                }
            }
            if let problem = appVolumes.problem {
                Text(problem).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(level: Float, isMuted: Bool, label: String, onChange: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 14, alignment: .leading) // glyph on the panel's left edge, like everything else
            ThinSlider(
                value: Double(level),
                label: label,
                valueDescription: isMuted ? "Muted" : "\(Int((level * 100).rounded()))%",
                onChange: { onChange(Float($0)) }
            )
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One icon per app in Now Playing, left to right. Click one to show and control it.
private struct SourceSwitcher: View {
    let nowPlaying: NowPlayingService

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(nowPlaying.sources) { source in
                    SourceIcon(source: source, isSelected: source.id == nowPlaying.selectedSourceID) {
                        nowPlaying.select(source)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: nowPlaying.selectedSourceID)
    }
}

private struct SourceIcon: View {
    let source: PlayingSource
    let isSelected: Bool
    let action: () -> Void

    /// Every icon is the same size, so the row lines up; selection is glass and opacity only.
    private let diameter: CGFloat = 32

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = source.app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "music.note").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .bottomTrailing) {
                if source.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 6, weight: .bold))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(.black.opacity(0.6)))
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.interactive() : .clear.interactive(), in: .circle)
        .opacity(isSelected ? 1 : 0.5)
        .help(source.name)
        .accessibilityLabel("\(source.name), \(source.isPlaying ? "playing" : "paused")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EmptyState: View {
    let problem: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: problem == nil ? "music.note" : "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .frame(width: 60, height: 60)
                .glassEffect(.regular, in: .circle)
                .padding(.bottom, 4)
            Text(problem == nil ? "Nothing playing" : "Can't read Now Playing").font(.headline)
            Text(problem ?? "Play something in Music, Spotify, or your browser.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Shared

/// A thin capsule slider that thickens on hover, for the scrubber and volume.
struct ThinSlider: View {
    /// 0...1
    let value: Double
    let label: String
    let valueDescription: String
    /// Fraction moved per VoiceOver increment/decrement. Clamped to 0...1 (see `sliderStep`).
    var step: Double = 0.0625
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let active = isHovering || isDragging
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.2))
                Capsule()
                    .fill(.primary.opacity(active ? 1 : 0.85))
                    .frame(width: width * min(max(value, 0), 1))
            }
            .frame(height: active ? 5 : 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onChange(min(max(drag.location.x / width, 0), 1))
                    }
                    .onEnded { drag in
                        isDragging = false
                        onCommit(min(max(drag.location.x / width, 0), 1))
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 12)
        // Present it to VoiceOver as a native slider.
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { value }, set: { newValue in
                    onChange(newValue)
                    onCommit(newValue)
                }),
                in: 0...1,
                step: sliderStep
            ) {
                Text(label)
            }
            .accessibilityValue(valueDescription)
        }
    }

    /// SwiftUI's Slider traps on a step that's not in (0, 1], e.g. the scrubber's
    /// 10 seconds of a 4-second voice message.
    private var sliderStep: Double {
        step.isFinite && step > 0 ? min(step, 1) : 0.0625
    }
}
