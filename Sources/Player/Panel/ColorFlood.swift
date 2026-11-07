import AppKit
import SwiftUI

/// Colours sampled from album artwork: a 3×3 grid, row-major from the top-left,
/// each the average of the matching region of the artwork.
nonisolated struct ArtworkPalette: Equatable, Sendable {
    /// sRGB components, 0...1. Plain numbers so two palettes can be blended.
    let cells: [SIMD3<Float>]

    static let neutral = ArtworkPalette(cells: Array(repeating: SIMD3(0.2, 0.2, 0.2), count: 9))

    var colors: [Color] {
        cells.map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
    }

    init(cells: [SIMD3<Float>]) {
        self.cells = cells
    }

    init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Draw small first (cheap, smooth), then average 10×10 blocks into the 3×3 grid.
        let side = 30, block = 10
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var cells: [SIMD3<Float>] = []
        for row in 0..<3 {          // bitmap memory starts at the top row
            for column in 0..<3 {
                var sum = SIMD3<Float>(0, 0, 0)
                for y in row * block..<(row + 1) * block {
                    for x in column * block..<(column + 1) * block {
                        let i = (y * side + x) * 4
                        sum += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                    }
                }
                cells.append(Self.floodColor(sum / Float(block * block * 255)))
            }
        }
        self.cells = cells
    }

    /// Brighter, punchier versions of a few cells, for small accents like the menu bar
    /// equalizer: light on a dark menu bar, deeper on a light one.
    func accentColors(count: Int, forDarkBackground dark: Bool) -> [NSColor] {
        let picks = [1, 3, 5, 7, 4, 0, 8, 2, 6] // edge midpoints first: they differ the most
        return (0..<count).map { index in
            let rgb = cells[picks[index % picks.count] % cells.count]
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let range: ClosedRange<CGFloat> = dark ? 0.82...1 : 0.42...0.62
            return NSColor(
                hue: hue,
                saturation: min(saturation * 1.25, 1),
                brightness: min(max(brightness * 1.6, range.lowerBound), range.upperBound),
                alpha: 1
            )
        }
    }

    /// Part-way from this palette to another, colour by colour.
    func blended(toward other: ArtworkPalette, amount: Float) -> ArtworkPalette {
        ArtworkPalette(cells: zip(cells, other.cells).map { $0 + ($1 - $0) * amount })
    }

    /// Keeps the hue, wins back the saturation that averaging regions loses, and holds
    /// brightness in a band where white text stays legible on any cover.
    private static func floodColor(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjusted = NSColor(
            hue: hue,
            saturation: min(saturation * 1.3, 1),
            brightness: min(max(brightness, 0.2), 0.62),
            alpha: 1
        ).usingColorSpace(.sRGB)!
        return SIMD3(Float(adjusted.redComponent), Float(adjusted.greenComponent), Float(adjusted.blueComponent))
    }
}

/// A slowly drifting mesh gradient of the artwork's colours: the panel's background.
/// New artwork cross-fades in colour by colour.
struct ColorFlood: View {
    let palette: ArtworkPalette
    /// Fade to new artwork only while the panel is on screen; otherwise just switch.
    let isVisible: Bool
    /// Drift only while the panel is open and music is playing.
    let isAnimating: Bool

    private let fadeDuration: TimeInterval = 1.8

    @State private var fadeFrom: ArtworkPalette?
    @State private var fadeTo: ArtworkPalette?
    @State private var fadeStart = Date.distantPast
    @State private var isFading = false
    @State private var fadeGeneration = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating && !isFading)) { context in
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                colors: shownPalette(at: context.date).colors
            )
        }
        .onChange(of: palette) { _, newPalette in
            guard isVisible else {
                endFade() // nobody's looking: switch instantly and keep the timeline paused
                return
            }
            // Start from whatever is on screen right now, even mid-fade, so it never jumps.
            fadeFrom = shownPalette(at: .now)
            fadeTo = newPalette
            fadeStart = .now
            isFading = true
            fadeGeneration += 1
            let generation = fadeGeneration
            // End by token, not by re-checking the clock: a timer firing a hair early once
            // left the fade (and a 30fps timeline in the hidden panel) running forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.1) {
                if generation == fadeGeneration { endFade() }
            }
        }
    }

    private func endFade() {
        isFading = false
        fadeFrom = nil
        fadeTo = nil
    }

    private func shownPalette(at date: Date) -> ArtworkPalette {
        guard let fadeFrom, let fadeTo else { return palette }
        let t = min(max(date.timeIntervalSince(fadeStart) / fadeDuration, 0), 1)
        let eased = t * t * t * (t * (t * 6 - 15) + 10) // smootherstep: gentle start and finish
        return fadeFrom.blended(toward: fadeTo, amount: Float(eased))
    }

    /// Corners stay put; the edge midpoints and centre wander gently.
    private static func points(at time: Double) -> [SIMD2<Float>] {
        func drift(_ phase: Double) -> Float { Float(sin(time * 0.4 + phase) * 0.09) }
        return [
            [0, 0], [0.5 + drift(0), 0], [1, 0],
            [0, 0.5 + drift(1.3)], [0.5 + drift(2.1), 0.5 + drift(3.7)], [1, 0.5 + drift(4.4)],
            [0, 1], [0.5 + drift(5.2), 1], [1, 1],
        ]
    }
}
