import SwiftUI

/// The kid's "Your tasks for today" picture: a sun coming up behind a tilted
/// checklist card (the static drawing is `TasksToday.svg`, same 240 × 240
/// coordinates). On arrival the first two rows tick themselves off, one after
/// the other; then the sun's rays turn slowly and two sparkles twinkle. With
/// Reduce Motion it's simply there.
struct TasksTodayArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checked = [false, false]
    @State private var ticks: [CGFloat] = [0, 0]
    @State private var spin = false
    @State private var twinkle = false

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

    private static let rows: [(y: CGFloat, bar: CGFloat)] = [(104, 56), (144, 44), (184, 60)]

    private var art: some View {
        ZStack {
            // The sun, rising behind the list.
            DrawnPath(Self.rays)
                .stroke(Color(hex: "FFD45C"), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(spin ? 45 : 0), anchor: Self.unit(172, 62))
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "FFE58A"), Color(hex: "FFB938")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .position(x: 172, y: 62)

            card.rotationEffect(.degrees(-6), anchor: Self.unit(112, 137))

            sparkle(Color(hex: "FFC94A"), size: 22, at: CGPoint(x: 34, y: 82), on: twinkle)
            sparkle(Color(hex: "6BD96A"), size: 16, at: CGPoint(x: 210, y: 176), on: !twinkle)
        }
    }

    private var card: some View {
        ZStack {
            // A raised card, like the kid's buttons: a deeper base under the face.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: "CDEFC6"))
                .frame(width: 132, height: 150)
                .position(x: 112, y: 144)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(hex: "E1F3DE"), lineWidth: 2))
                .frame(width: 132, height: 150)
                .position(x: 112, y: 137)

            // The clip.
            Capsule().fill(Color(hex: "3FCE64")).frame(width: 52, height: 18).position(x: 112, y: 62)
            Circle().fill(Color.white).frame(width: 8, height: 8).position(x: 112, y: 62)

            ForEach(0..<3, id: \.self) { i in row(i) }
        }
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let r = Self.rows[i]
        let done = i < checked.count && checked[i]
        Circle()
            .stroke(Color(hex: "D6E9D3"), lineWidth: 4)
            .frame(width: 24, height: 24)
            .position(x: 78, y: r.y)
        if i < checked.count {
            Circle()
                .fill(Color(hex: "3FCE64"))
                .frame(width: 28, height: 28)
                .scaleEffect(done ? 1 : 0.01)
                .position(x: 78, y: r.y)
            DrawnPath(Self.tick(y: r.y))
                .trim(from: 0, to: ticks[i])
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        Capsule()
            .fill(Color(hex: done ? "C4ECBE" : "E9EFE8"))
            .frame(width: r.bar, height: 14)
            .position(x: 102 + r.bar / 2, y: r.y)
    }

    private func sparkle(_ color: Color, size: CGFloat, at p: CGPoint, on: Bool) -> some View {
        Sparkle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1 : 0.6)
            .opacity(on ? 1 : 0.5)
            .position(p)
    }

    private func play() {
        guard !reduceMotion else {
            checked = [true, true]; ticks = [1, 1]; twinkle = true
            return
        }
        for i in 0..<2 {
            let start = 0.35 + Double(i) * 0.45
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(start)) { checked[i] = true }
            withAnimation(.easeOut(duration: 0.25).delay(start + 0.12)) { ticks[i] = 1 }
        }
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(1.2)) { twinkle = true }
    }

    private static func unit(_ x: CGFloat, _ y: CGFloat) -> UnitPoint { UnitPoint(x: x / 240, y: y / 240) }

    // MARK: - Shapes (TasksToday.svg, point for point)

    /// Eight short rays around the sun at (172, 62).
    private static let rays = Path { p in
        for k in 0..<8 {
            let a = Double(k) * .pi / 4
            p.move(to: CGPoint(x: 172 + 36 * cos(a), y: 62 + 36 * sin(a)))
            p.addLine(to: CGPoint(x: 172 + 46 * cos(a), y: 62 + 46 * sin(a)))
        }
    }

    private static func tick(y: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 71, y: y))
            p.addLine(to: CGPoint(x: 76, y: y + 5))
            p.addLine(to: CGPoint(x: 85, y: y - 5))
        }
    }
}

/// A four-pointed sparkle with curved sides.
private struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return Path { p in
            p.move(to: CGPoint(x: c.x, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: c)
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: c)
            p.closeSubpath()
        }
    }
}

/// A path drawn in a 240 × 240 frame.
private struct DrawnPath: Shape {
    let path: Path
    init(_ path: Path) { self.path = path }
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(scaleX: rect.width / 240, y: rect.height / 240))
    }
}

#Preview {
    TasksTodayArt().frame(height: 220).padding()
}
