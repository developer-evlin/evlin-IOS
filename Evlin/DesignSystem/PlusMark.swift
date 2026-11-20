import SwiftUI

/// Evlin's flame-leaf (the logo's shape, and the big leaf in HabitsToday.svg),
/// fitted to whatever frame it's given. Its tip flicks up like a flame.
struct FlameLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        Self.leaf.applying(Self.fit(rect))
    }

    /// Where the leaf meets its stem: turn it around this.
    static let base = UnitPoint(x: (121 - box.minX) / box.width, y: (116 - box.minY) / box.height)

    // Drawn in HabitsToday.svg's coordinates; `box` is the leaf's bounds there.
    private static let box = CGRect(x: 112, y: 48, width: 54, height: 70)

    private static func fit(_ rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / box.width, y: rect.height / box.height)
            .translatedBy(x: -box.minX, y: -box.minY)
    }

    private static let leaf = Path { p in
        p.move(to: CGPoint(x: 121, y: 116))
        p.addCurve(to: CGPoint(x: 136, y: 70), control1: CGPoint(x: 113, y: 98), control2: CGPoint(x: 119, y: 80))
        p.addCurve(to: CGPoint(x: 152, y: 50), control1: CGPoint(x: 144, y: 65), control2: CGPoint(x: 150, y: 59))
        p.addCurve(to: CGPoint(x: 158, y: 96), control1: CGPoint(x: 162, y: 64), control2: CGPoint(x: 165, y: 82))
        p.addCurve(to: CGPoint(x: 121, y: 116), control1: CGPoint(x: 150, y: 110), control2: CGPoint(x: 138, y: 116))
        p.closeSubpath()
    }
}

/// The Evlin Pro mark: Evlin's leaf on a light green tile, flickering
/// gently like a flame. Grey and still on the free plan; still with Reduce
/// Motion, or when `animated` is off.
struct PlusMark: View {
    var size: CGFloat = 34
    /// The free plan's version: a grey tile and a grey leaf.
    var muted = false
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flicker = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(muted ? Color(light: "ECECEF", dark: "353A42") : Color(light: "E3F7DD", dark: "17301F"))
            FlameLeaf()
                .fill(muted ? Color(hex: "B4B4BA") : Color(hex: "3FCE64"))
                .frame(width: size * 0.42, height: size * 0.54)
                .rotationEffect(.degrees(flicker ? 6 : -4), anchor: FlameLeaf.base)
                .scaleEffect(flicker ? 1.04 : 0.97, anchor: FlameLeaf.base)
                .offset(x: -size * 0.03, y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            guard animated, !muted, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { flicker = true }
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        PlusMark()
        PlusMark(size: 32, muted: true)
        PlusMark(size: 64)
        FlameLeaf().fill(Color.white).frame(width: 14, height: 18)
            .padding(6).background(Capsule().fill(Color(hex: "3FCE64")))
    }
    .padding()
}
