// Writes Player's app icon as an Icon Composer document (Resources/AppIcon.icon): a play
// glyph in Liquid Glass over a green-teal contour field. Layered, so macOS 26 can render it
// properly in every icon style (Default, Dark, Clear, Tinted). Run from the project root:
//
//     swift scripts/make-icon.swift
//
// Open Resources/AppIcon.icon in Icon Composer (Xcode › Open Developer Tool) to fine-tune.
import AppKit

let side = 1024
let size = CGFloat(side)

// Sampled from the reference artwork.
let lime = (0.65, 0.86, 0.49)     // #A6DC7C highlight, top left
let teal = (0.06, 0.35, 0.33)     // #0F5A55 deep teal, bottom right
let night = (0.01, 0.22, 0.18)    // #03382E shadowed corners

let bundle = URL(fileURLWithPath: "Resources/AppIcon.icon", isDirectory: true)
let assets = bundle.appending(path: "Assets", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

/// Draws into a transparent 1024² image and saves it as a PNG layer.
func layer(_ name: String, draw: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: assets.appending(path: name))
}

func radial(_ context: CGContext, center: CGPoint, radius: CGFloat, rgb: (Double, Double, Double), alpha: Double) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, alpha])!,
                  CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 0])!]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// Light falling on a folded surface: a lime glow top-left, deep shade bottom-right.
try layer("glow.png") { radial($0, center: CGPoint(x: size * 0.1, y: size * 0.9), radius: size * 0.7, rgb: lime, alpha: 0.75) }
try layer("shade.png") { radial($0, center: CGPoint(x: size * 0.95, y: size * 0.05), radius: size * 0.75, rgb: night, alpha: 0.8) }

// Topographic contour lines: stacked waves bending around a soft ridge.
try layer("contours.png") { context in
    context.setLineWidth(2.4)
    let count = 46
    for index in 0..<count {
        let t = CGFloat(index) / CGFloat(count - 1)
        let path = CGMutablePath()
        for step in 0...64 {
            let u = CGFloat(step) / 64
            let ridge = sin(u * .pi * 1.3 + t * 2.2) * size * 0.07
            let fold = exp(-pow((u - 0.35 - t * 0.2) * 3.2, 2)) * size * 0.16
            let point = CGPoint(x: u * size, y: size * (1.15 - t * 1.3) + ridge + fold - u * size * 0.18)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let alpha = 0.35 + 0.45 * min(max(1 - abs(t - 0.45) * 1.6, 0), 1)
        context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        context.addPath(path)
        context.strokePath()
    }
}

// The play glyph as SVG: a rounded triangle, nudged right so it looks optically centred.
let height = size * 0.40, width = height * 0.88, stroke = size * 0.075
let cx = size * 0.5 + width * 0.08, cy = size * 0.5
let playSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(side)" height="\(side)" viewBox="0 0 \(side) \(side)">
  <path d="M \(cx - width / 2) \(cy - height / 2) L \(cx + width / 2) \(cy) L \(cx - width / 2) \(cy + height / 2) Z"
        fill="#FFFFFF" stroke="#FFFFFF" stroke-width="\(stroke)" stroke-linejoin="round"/>
</svg>
"""
try playSVG.write(to: assets.appending(path: "play.svg"), atomically: true, encoding: .utf8)

func srgb(_ c: (Double, Double, Double)) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.0, c.1, c.2) }

// Groups are listed front to back.
let document: [String: Any] = [
    "fill": [
        "linear-gradient": [srgb(lime), srgb(teal)],
        "orientation": ["start": ["x": 0.15, "y": 0.0], "stop": ["x": 0.85, "y": 1.0]],
    ],
    "groups": [
        [
            "name": "Play",
            "layers": [["name": "Play", "image-name": "play.svg", "glass": true]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.35],
            "specular": true,
        ],
        [
            "name": "Field",
            "layers": [
                ["name": "Contours", "image-name": "contours.png", "glass": false, "opacity": 0.22],
                ["name": "Glow", "image-name": "glow.png", "glass": false],
                ["name": "Shade", "image-name": "shade.png", "glass": false],
            ],
            "shadow": ["kind": "none", "opacity": 0],
            "translucency": ["enabled": false, "value": 0],
            "specular": false,
        ],
    ],
    "supported-platforms": ["squares": "shared"],
]
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: bundle.appending(path: "icon.json"))
print("Wrote \(bundle.path)")
