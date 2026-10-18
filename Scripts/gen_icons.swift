/// Generates the 4 status gauge PNGs for the menu bar by painting pixels
/// DIRECTLY with CoreGraphics — no SF Symbol dependency. The previous masked-
/// symbol pipeline once shipped 32x32 PNGs that were ~100% transparent (the
/// glyphs rendered empty in some environments), so an image "loads" but draws
/// nothing — the root cause of the invisible menu bar item.
///
/// Design (bold on purpose; masks down to 18pt in the bar):
///   - thick ring in the status color (38% alpha, reads on light & dark bars)
///   - solid status arc (a ~70% gauge sweep) on the low-alpha ring
///   - solid center dot — the "credit pulse"
///
/// Out: Sources/AICreditPulseCore/Resources/icon-{green,amber,red,grey}.png
/// (single 64px canvas; the app presents it at 18pt for Retina-crisp look)
///
/// Build: swiftc Scripts/gen_icons.swift -o /tmp/gen_icons && cd <root> && /tmp/gen_icons
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let statuses: [(name: String, rgbs: (Float, Float, Float))] = [
    ("green", (0.20, 0.80, 0.35)),   // #34C759-adjacent
    ("amber", (1.00, 0.62, 0.04)),   // #FF9F0A
    ("red", (1.00, 0.27, 0.23)),    // #FF453A
    ("grey", (0.60, 0.63, 0.67)),   // #98A2AD
]

let dim = 64.0
// Weak ring / solid arc geometry
let ringOuter = dim / 2.0 - 3.0   // 29
let ringWidth = 7.0
let dotRadius = 8.5
let arcFraction = 0.72            // the "pulse" sweep of the free credits

for status in statuses {
    let context = CGContext(
        data: nil, width: Int(dim), height: Int(dim), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let color = CGColor(srgbRed: CGFloat(status.rgbs.0), green: CGFloat(status.rgbs.1),
                        blue: CGFloat(status.rgbs.2), alpha: 1)
    context.setLineCap(.round)

    // 1. Full background ring — status color at low alpha for bar contrast.
    context.setStrokeColor(color.copy(alpha: 0.42)!)
    context.setLineWidth(ringWidth)
    context.strokeEllipse(in: CGRect(
        x: ringOuter - ringOuter + 1, y: 1, width: dim - 2, height: dim - 2))

    // 2. Solid sweep arc on top of the ring (starts at 12 o'clock, clockwise).
    let center = CGPoint(x: dim / 2, y: dim / 2)
    let startAngle = CGFloat.pi / 2
    let sweep = CGFloat(arcFraction) * 2.0 * .pi
    context.setStrokeColor(color)
    context.setLineWidth(ringWidth + 2)
    context.addArc(center: center, radius: ringOuter - 1,
                   startAngle: startAngle + 2.0 * .pi * (1 - arcFraction),
                   endAngle: startAngle + 2.0 * .pi,
                   clockwise: false)
    context.strokePath()

    // 3. Center dot — the pulse.
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(
        x: center.x - dotRadius, y: center.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2))

    // 4. Encode + verify ink:
    let image = context.makeImage()!
    let url = URL(fileURLWithPath: "Sources/AICreditPulseCore/Resources/icon-\(status.name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { print("encode failed"); exit(1) }

    // Ink proof: strong-opaque pixels must be a meaningful fraction.
    var buf = [UInt8](repeating: 0, count: Int(dim) * Int(dim) * 4)
    let check = CGContext(
        data: &buf, width: Int(dim), height: Int(dim), bitsPerComponent: 8,
        bytesPerRow: Int(dim) * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    check.draw(image, in: CGRect(x: 0, y: 0, width: dim, height: dim))
    var opaque = 0
    for i in stride(from: 3, to: Int(dim) * Int(dim) * 4, by: 4) where buf[i] > 200 {
        opaque += 1
    }
    if opaque < Int(Double(dim) * Double(dim) * 0.15) {
        print("FAIL \(status.name): only \(opaque) opaque pixels")
        exit(1)
    }
    print("wrote \(url.path) opaque=\(opaque)/\(Int(dim) * Int(dim))")
}
print("done")
