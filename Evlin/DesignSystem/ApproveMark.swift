import SwiftUI

/// The approval check, drawn as a path (an SVG's `M5 12.5 L9.8 17.2 L19 7.5`
/// in a 24-point box) rather than SF Symbols' checkmark: rounded ends and
/// joins, a short leg and a long one, so it can draw itself in on a tap the
/// way Apple Pay's and Things' checks do. `progress` 0…1 is how much of it
/// is drawn; animate it to draw the stroke.
struct ApproveCheckShape: Shape {
    var progress: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        path.move(to: p(5, 12.5))
        path.addLine(to: p(9.8, 17.2))
        path.addLine(to: p(19, 7.5))
        return path.trimmedPath(from: 0, to: progress)
    }
}

/// How thick the check's line is for its box: the stem of the buttons'
/// heavy 15-point type (about 2.5 points) over the check's box beside it
/// (22 points). The stamp uses the same ratio, so every check in the deck
/// is the same weight as the "Approve" lettering, just larger.
let approveCheckStroke: CGFloat = 0.115

/// The check beside text, sized from the text's font: as tall as its
/// capitals and as heavy as its letters.
struct ApproveCheck: View {
    var fontSize: CGFloat = 15
    var progress: CGFloat = 1

    private var box: CGFloat { fontSize * 1.45 }

    var body: some View {
        ApproveCheckShape(progress: progress)
            .stroke(style: StrokeStyle(lineWidth: box * approveCheckStroke, lineCap: .round, lineJoin: .round))
            .frame(width: box, height: box)
            .accessibilityHidden(true)
    }
}

/// The green approval badge: a disc lit softly from the top, with the
/// check drawn in white. `drawn` draws the check (animate it after the
/// disc has popped in).
struct ApproveBadge: View {
    var size: CGFloat = 104
    var drawn: Bool = true

    static let green = Color(hex: "25924A")
    private static let light = Color(hex: "3DB866")

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Self.light, Self.green], startPoint: .top, endPoint: .bottom))
            // A thin inner edge, lighter at the top: reads as a surface,
            // not a flat sticker.
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: max(1, size / 70))
            ApproveCheckShape(progress: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.56 * approveCheckStroke, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.56, height: size * 0.56)
                // Drawn once the disc is in, quick and even.
                .animation(drawn ? .easeOut(duration: 0.3).delay(0.1) : nil, value: drawn)
        }
        .frame(width: size, height: size)
        .shadow(color: Self.green.opacity(0.35), radius: size / 7, y: size / 16)
        .accessibilityElement()
        .accessibilityLabel("Approved")
    }
}

/// "Approve" / "Approved" with the drawn check, in the deck buttons' own
/// type (heavy, 15). `progress` draws the check in.
struct ApproveLabel: View {
    var title: String
    var progress: CGFloat = 1

    static let fontSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 5) {
            ApproveCheck(fontSize: Self.fontSize, progress: progress)
            Text(title)
        }
        .font(Typography.font(Self.fontSize, weight: .heavy))
    }
}

#Preview {
    VStack(spacing: 30) {
        ApproveBadge()
        ApproveBadge(size: 56)
        ApproveLabel(title: "Approve")
    }
    .padding()
}
