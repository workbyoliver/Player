import SwiftUI

/// Single-line text that truncates, and scrolls in a loop while `isScrolling` is on
/// (only if it doesn't fit).
struct MarqueeText: View {
    let text: String
    let font: NSFont
    let textWidth: CGFloat
    let maxWidth: CGFloat
    let isScrolling: Bool

    private let gap: CGFloat = 36
    private let speed: CGFloat = 32 // points per second
    private let startDelay: TimeInterval = 0.35

    @State private var scrollStart: Date?

    private var overflows: Bool { textWidth > maxWidth }

    var body: some View {
        Group {
            if overflows, let scrollStart {
                // 30fps is plenty for scrolling text, and in the menu bar every frame is
                // re-snapshotted by AppKit, so don't run at the display's full rate.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let seconds = max(0, context.date.timeIntervalSince(scrollStart) - startDelay)
                    let offset = (CGFloat(seconds) * speed).truncatingRemainder(dividingBy: textWidth + gap)
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: -offset)
                }
                .frame(width: maxWidth, alignment: .leading)
                .clipped()
                .mask(edgeFade)
            } else {
                Text(text)
                    .font(Font(font))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: min(textWidth, maxWidth), alignment: .leading)
            }
        }
        .onChange(of: isScrolling, initial: true) { restart() }
        .onChange(of: text) { restart() }
    }

    private var label: some View {
        Text(text).font(Font(font)).lineLimit(1).fixedSize()
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func restart() {
        scrollStart = isScrolling && overflows ? .now : nil
    }
}
