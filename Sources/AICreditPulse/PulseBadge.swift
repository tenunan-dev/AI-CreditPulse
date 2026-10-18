import SwiftUI

/// The brand badge drawn in SwiftUI — the same navy field, violet gradient and
/// green credit pulse as the generated app icon (Scripts/make_icon.swift), so
/// the window header and Dock icon read as one brand at any scale.
struct PulseBadge: View {
    var side: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.224, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.165, green: 0.190, blue: 0.290),
                             Color(red: 0.085, green: 0.085, blue: 0.170)],
                    startPoint: .top, endPoint: .bottom))
            PulseShape()
                .stroke(Color(red: 0.34, green: 0.80, blue: 0.47), style: StrokeStyle(
                    lineWidth: side * 0.033, lineCap: .round, lineJoin: .round))
                .padding(side * 0.062)
            RoundedRectangle(cornerRadius: side * 0.224, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .frame(width: side, height: side)
    }
}

/// The pulse polyline on the 1024-unit design grid, normalized to the shape's rect.
struct PulseShape: Shape {
    static let points: [CGPoint] = [
        CGPoint(x: 140, y: 520), CGPoint(x: 340, y: 520), CGPoint(x: 400, y: 535),
        CGPoint(x: 455, y: 295), CGPoint(x: 525, y: 735), CGPoint(x: 590, y: 345),
        CGPoint(x: 650, y: 535), CGPoint(x: 705, y: 520), CGPoint(x: 884, y: 520),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in Self.points.enumerated() {
            let p = CGPoint(
                x: rect.minX + point.x / 1024 * rect.width,
                y: rect.minY + point.y / 1024 * rect.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
