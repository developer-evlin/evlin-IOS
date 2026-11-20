import SwiftUI

/// The last parent setup screen's picture: a habit ring filling up to today,
/// with a sprout of Evlin's flame-leaves inside (the static drawing is
/// `HabitsToday.svg`, same 240 × 240 coordinates). On arrival the ring fills,
/// today's dot appears, the stem grows and the leaves open; then the ring
/// edges forward and back a little, today's dot riding its end, and the
/// leaves sway gently, like a flame. With Reduce Motion it's simply there.
struct HabitsTodayArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var dot = false
    @State private var stem: CGFloat = 0
    @State private var leaves: CGFloat = 0
    @State private var sway = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            art
                .frame(width: 240, height: 240)
                .scaleEffect(side / 240)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear(perform: play)
    }

    private var art: some View {
        ZStack {
            // The habit ring: a track, and three quarters of it filled.
            Circle()
                .stroke(Color(hex: "E4F6E3"), lineWidth: 16)
                .frame(width: 192, height: 192)
                .position(x: 120, y: 120)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Color(hex: "3FCE64"), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 192, height: 192)
                .position(x: 120, y: 120)

            // Today, at the end of the ring, following it along the arc.
            ZStack {
                RingEndDot(progress: ring).fill(Color(hex: "25924A"))
                RingEndDot(progress: ring).stroke(Color.white, lineWidth: 6)
            }
            .scaleEffect(dot ? 1 : 0, anchor: RingEndDot.anchor(at: ring))

            // The sprout.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: "D0F1C9"))
                .frame(width: 72, height: 18)
                .position(x: 120, y: 173)
            ArtPath(Self.stemPath)
                .trim(from: 0, to: stem)
                .stroke(Color(hex: "25924A"), style: StrokeStyle(lineWidth: 9, lineCap: .round))

            ArtPath(Self.smallLeaf)
                .fill(LinearGradient(colors: [Color(hex: "D6F79A"), Color(hex: "6BD96A")],
                                     startPoint: Self.unit(74, 88), endPoint: Self.unit(118, 136)))
                .scaleEffect(leaves, anchor: Self.unit(118.5, 136))
                .rotationEffect(.degrees(sway ? -4 : 2), anchor: Self.unit(118.5, 136))

            ZStack {
                ArtPath(Self.bigLeaf)
                    .fill(LinearGradient(colors: [Color(hex: "BEF06B"), Color(hex: "3FCE64")],
                                         startPoint: Self.unit(152, 50), endPoint: Self.unit(124, 116)))
                ArtPath(Self.bigLeafSwoosh)
                    .fill(Color.white.opacity(0.75))
            }
            .scaleEffect(leaves, anchor: Self.unit(121, 116))
            .rotationEffect(.degrees(sway ? 5 : -2), anchor: Self.unit(121, 116))
        }
    }

    private func play() {
        guard !reduceMotion else {
            ring = 0.75; dot = true; stem = 1; leaves = 1
            return
        }
        withAnimation(.easeOut(duration: 0.9)) { ring = 0.75 }
        withAnimation(.smooth(duration: 0.3).delay(0.85)) { dot = true }
        withAnimation(.easeOut(duration: 0.45).delay(0.25)) { stem = 1 }
        withAnimation(.smooth(duration: 0.5).delay(0.6)) { leaves = 1 }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(1.2)) { sway = true }
        // Then the ring keeps edging forward and back a little.
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true).delay(1.2)) { ring = 0.81 }
    }

    private static func unit(_ x: CGFloat, _ y: CGFloat) -> UnitPoint { UnitPoint(x: x / 240, y: y / 240) }

    // MARK: - Shapes (HabitsToday.svg, point for point)

    /// From the base up, so trimming it grows the stem upward.
    private static let stemPath = Path { p in
        p.move(to: CGPoint(x: 120, y: 168))
        p.addCurve(to: CGPoint(x: 121, y: 112), control1: CGPoint(x: 120, y: 146), control2: CGPoint(x: 117, y: 128))
    }

    private static let smallLeaf = Path { p in
        p.move(to: CGPoint(x: 118.5, y: 136))
        p.addCurve(to: CGPoint(x: 84, y: 106), control1: CGPoint(x: 100, y: 134), control2: CGPoint(x: 86, y: 122))
        p.addCurve(to: CGPoint(x: 74, y: 88), control1: CGPoint(x: 83, y: 98), control2: CGPoint(x: 79, y: 92))
        p.addCurve(to: CGPoint(x: 112, y: 106), control1: CGPoint(x: 90, y: 88), control2: CGPoint(x: 104, y: 94))
        p.addCurve(to: CGPoint(x: 118.5, y: 136), control1: CGPoint(x: 117, y: 114), control2: CGPoint(x: 119, y: 124))
        p.closeSubpath()
    }

    /// The flame-leaf: its tip flicks up like a flame's, as in the logo.
    private static let bigLeaf = Path { p in
        p.move(to: CGPoint(x: 121, y: 116))
        p.addCurve(to: CGPoint(x: 136, y: 70), control1: CGPoint(x: 113, y: 98), control2: CGPoint(x: 119, y: 80))
        p.addCurve(to: CGPoint(x: 152, y: 50), control1: CGPoint(x: 144, y: 65), control2: CGPoint(x: 150, y: 59))
        p.addCurve(to: CGPoint(x: 158, y: 96), control1: CGPoint(x: 162, y: 64), control2: CGPoint(x: 165, y: 82))
        p.addCurve(to: CGPoint(x: 121, y: 116), control1: CGPoint(x: 150, y: 110), control2: CGPoint(x: 138, y: 116))
        p.closeSubpath()
    }

    private static let bigLeafSwoosh = Path { p in
        p.move(to: CGPoint(x: 126, y: 110))
        p.addCurve(to: CGPoint(x: 140, y: 74), control1: CGPoint(x: 120, y: 96), control2: CGPoint(x: 126, y: 82))
        p.addCurve(to: CGPoint(x: 152, y: 56), control1: CGPoint(x: 146, y: 70), control2: CGPoint(x: 150, y: 64))
        p.addCurve(to: CGPoint(x: 135, y: 86), control1: CGPoint(x: 150, y: 70), control2: CGPoint(x: 143, y: 79))
        p.addCurve(to: CGPoint(x: 126, y: 110), control1: CGPoint(x: 129, y: 92), control2: CGPoint(x: 126, y: 100))
        p.closeSubpath()
    }
}

/// Today's dot, centred on the end of the ring at `progress` (0 at the top,
/// going clockwise). Animatable, so it travels along the arc rather than
/// cutting across it.
private struct RingEndDot: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static func point(at progress: CGFloat) -> CGPoint {
        let angle = (-90 + 360 * Double(progress)) * .pi / 180
        return CGPoint(x: 120 + 96 * cos(angle), y: 120 + 96 * sin(angle))
    }

    static func anchor(at progress: CGFloat) -> UnitPoint {
        let p = point(at: progress)
        return UnitPoint(x: p.x / 240, y: p.y / 240)
    }

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 240
        let c = Self.point(at: progress)
        return Path(ellipseIn: CGRect(x: (c.x - 15) * scale, y: (c.y - 15) * scale, width: 30 * scale, height: 30 * scale))
    }
}

/// A path drawn in a 240 × 240 frame.
private struct ArtPath: Shape {
    let path: Path
    init(_ path: Path) { self.path = path }
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(scaleX: rect.width / 240, y: rect.height / 240))
    }
}

#Preview {
    HabitsTodayArt().frame(height: 200).padding()
}
