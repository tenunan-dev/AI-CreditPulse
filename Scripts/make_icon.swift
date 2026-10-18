/// One-off generator: renders the AI CreditPulse brand artwork into
/// Assets/AppIcon.iconset (all macOS icon sizes) and Assets/AppLogo.png at 512.
/// The same pulse geometry is mirrored in PulseBadge (Sources/AICreditPulse) so
/// the window header, the Dock/Finder icon and the menu bar gauges read as one
/// brand: a dark navy field, a violet gradient, and one green credit pulse.
///
/// Build & run:
///   swiftc -sdk <macosx sdk> Scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon
///   iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Pulse polyline on the 1024 design grid: a flat baseline that breaks into the
/// classic ECG spike — the "credit pulse".
let pulsePoints: [(CGFloat, CGFloat)] = [
    (140, 520), (340, 520), (400, 535), (455, 295), (525, 735),
    (590, 345), (650, 535), (705, 520), (884, 520),
]

func pulseStroke(_ size: CGFloat, alpha: CGFloat, width: CGFloat, color: NSColor) {
    let f = size / 1024
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = width * f
    for (index, point) in pulsePoints.enumerated() {
        let p = NSPoint(x: point.0 * f, y: point.1 * f)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    color.setStroke()
    path.stroke()
}

func render(_ size: CGFloat, background: Bool) -> Data {
    let f = size / 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    if background {
        // Rounded-square field (macOS icon proportions), navy → violet.
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let field = NSBezierPath(roundedRect: rect, xRadius: 230 * f, yRadius: 230 * f)
        field.addClip()
        let gradient = NSGradient(
            colors: [
                NSColor(srgbRed: 0.165, green: 0.190, blue: 0.290, alpha: 1),
                NSColor(srgbRed: 0.085, green: 0.085, blue: 0.170, alpha: 1),
            ])!
        gradient.draw(in: field, angle: 90)
        // Soft inner edge for definition on light backgrounds.
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5 * f, dy: 1.5 * f),
                                xRadius: 229 * f, yRadius: 229 * f)
        edge.lineWidth = 3 * f
        NSColor.white.withAlphaComponent(0.07).setStroke()
        edge.stroke()
    }

    // Glow passes beneath the crisp pulse line (a credit EKG).
    pulseStroke(size, alpha: 0.08, width: 120, color: NSColor(srgbRed: 0.34, green: 0.80, blue: 0.47, alpha: 0.08))
    pulseStroke(size, alpha: 0.18, width: 70, color: NSColor(srgbRed: 0.34, green: 0.80, blue: 0.47, alpha: 0.18))
    pulseStroke(size, alpha: 1.0, width: 34, color: NSColor(srgbRed: 0.34, green: 0.80, blue: 0.47, alpha: 1.0))
    // A small pulsing beat dot on the spike peak.
    let peak = pulsePoints[4]
    let dot = NSBezierPath(
        roundedRect: NSRect(x: peak.0 * f - 17 * f, y: peak.1 * f - 17 * f, width: 34 * f, height: 34 * f),
        xRadius: 17 * f, yRadius: 17 * f)
    NSColor.white.withAlphaComponent(0.9).setFill()
    dot.fill()

    return rep.representation(using: .png, properties: [:])!
}

// Iconset entries: standard macOS sizes, each with its @2x partner.
let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    let data = render(size, background: true)
    try data.write(to: iconset.appendingPathComponent(name))
    print("wrote \(name) (\(Int(size))px)")
}

// Standalone logo (same badge, no background crop) for reuse/docs.
try render(512, background: true)
    .write(to: root.appendingPathComponent("Assets/AppLogo.png"))
print("wrote Assets/AppLogo.png (512px)")
