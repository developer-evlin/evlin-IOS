import SwiftUI
import UIKit

/// The round button beside a child's progress: an icon in a raised white
/// circle. A plain tap that acts at once: nothing slides, nothing pops.
///
/// - Locking, unlocking: a tap gives a medium tap of vibration and acts.
///   The change shows afterwards, beside it: the bar, the time and the
///   colours ease into the new state.
/// - Approving (`tapActs`, everything sent in): solid in `fill`, still (no
///   glow behind it, 2026-11-05); a tap acts at once, with the success haptic.
/// - VoiceOver: a double-tap acts at once.
struct HoldToActButton<Icon: View>: View {
    /// The icon's colour at rest.
    var tint: Color
    /// The approve face's colour.
    var fill: Color
    var enabled: Bool = true
    /// Approving: acts at once, solid and glowing.
    var tapActs: Bool = false
    var accessibilityLabel: String
    /// The circle's width; the icon scales with it.
    var size: CGFloat = 84
    var onComplete: () -> Void
    @ViewBuilder var icon: () -> Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A finger is down on it and hasn't wandered off.
    @State private var pressedIn = false
    /// The parent has approved everything at least once.
    @AppStorage("evlin.approveAllLearned") private var approveLearned = false
    /// A finger is on it. A gesture state, so it resets on every lift and
    /// on every cancel: the press can never get stuck "down".
    @GestureState private var touching = false

    /// The resting face, from its lit top left (`lift`) to `rest`, with a
    /// faint edge and two shadows: dark below right, light above left. In
    /// Cream it's built from the page's own cream, never white: a white face
    /// at this size glared (2026-11-07).
    /// In Dark it's flat: one charcoal, a fine rim and one soft shadow (the
    /// gradient and the light glow looked muddy there, 2026-11-07).
    private static var rest: Color { RaisedFace.rest }
    private static var lift: Color { RaisedFace.lift }
    /// A neutral rim that outlines it on the page.
    private static var rim: Color { RaisedFace.rim }
    private static var lowShadow: Color { RaisedFace.lowShadow }
    private static var highShadow: Color { RaisedFace.highShadow }

    private static var morph: Animation { .interpolatingSpring(stiffness: 140, damping: 20) }

    var body: some View {
        circle
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { onComplete() } }
    }

    private var circle: some View {
        ZStack {
            // At rest: soft and raised out of the page (neumorphic), lit
            // from the top left: a lighter face, a dark shadow below right and
            // a light one above left, so it reads as a button on either page.
            // Tap mode: the action's colour, flat.
            // At rest a neutral warm grey a step deeper than the page, with a
            // grey rim: white glared, cream alone blended in, and a wash of
            // red or green was too much (2026-11-07). Only the icon has colour.
            Circle()
                .fill(LinearGradient(colors: [Self.lift, Self.rest], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(Self.rim.opacity(tapActs ? 0 : 1), lineWidth: 1.5))
                // The approve face: grows out from the middle when everything's
                // in, and drains back into it once approved, uncovering the
                // resting face (2026-11-08: a crossfade was too plain).
                .overlay(Circle().fill(fill)
                    .scaleEffect(tapActs || reduceMotion ? 1 : 0.02)
                    .opacity(tapActs ? 1 : 0))
                .shadow(color: Self.lowShadow.opacity(tapActs ? 0 : 1), radius: size * 0.07, x: size * 0.035, y: size * 0.05)
                .shadow(color: Self.highShadow.opacity(tapActs ? 0 : 1), radius: size * 0.07, x: -size * 0.035, y: -size * 0.035)
            icon()
                .foregroundStyle(tapActs ? .white : tint)
                .frame(width: size * 0.34, height: size * 0.34)
        }
        .frame(width: size, height: size)

        // Pressed: dimmed and a touch smaller, as if pushed in.
        .opacity(pressedIn ? 0.8 : 1)
        .scaleEffect(pressedIn ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: pressedIn)
        .animation(Self.morph, value: tapActs)
        .animation(.easeInOut(duration: 0.45), value: tint)
        .opacity(enabled ? 1 : 0.6)
        // A bit more than the circle takes a press, so it's easy to hit.
        .contentShape(Circle().inset(by: -8))
        .gesture(enabled ? press : nil)
        .onChange(of: touching) { _, down in
            if down {
                pressedIn = true
            } else {
                lifted()
            }
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                // A finger that slides well off is a let-go, not a tap.
                if hypot(value.translation.width, value.translation.height) > 70 { pressedIn = false }
            }
    }

    /// The finger's off: if it was still on the button, that's the tap.
    private func lifted() {
        let tapped = pressedIn
        pressedIn = false
        guard tapped else { return }
        if tapActs {
            approveLearned = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        onComplete()
    }
}

/// The lock button's resting face.
enum RaisedFace {
    static var rest: Color { Color(light: "EFEFF4", dark: "2B2F36") }
    static var lift: Color { Color(light: "F7F7FA", dark: "2B2F36") }
    static var rim: Color { Color(light: "E5E5EA", dark: "3D424B") }
    static var lowShadow: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.35) : UIColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 0.24) }) }
    static var highShadow: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0) : UIColor(white: 1, alpha: 0.6) }) }

}

/// A child's progress beside the button: the status in words over a thin
/// bar, still (the light that ran along it was removed, 2026-11-05). A
/// change of state eases in: the fill, its colour and the counting time move together.
struct StatusProgress: View {
    var text: String
    var suffix: String?
    var textColor: Color
    var fraction: CGFloat
    var color: Color
    /// The words are a state ("Locked") with a sentence under it, not a
    /// number with a few words after it.
    var stacked: Bool = false
    /// The time left in minutes, when `text` is a time: it counts to the
    /// new value as the bar moves, on the same curve (from 0 when the
    /// phone has just opened).
    var minutes: Int? = nil

    /// The bar and the counting time move together on this.
    static let together = Animation.easeInOut(duration: 0.9)
    @State private var shownMinutes: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stacked {
                // A state, not a count: a title, and a plain sentence under
                // it in secondary grey (Apple's title + subtitle).
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(Typography.font(24, weight: .medium))
                        .tracking(-0.2)
                        .foregroundStyle(textColor)
                    if let suffix {
                        Text(suffix)
                            .font(Typography.font(15, weight: .regular))
                            .foregroundStyle(StatusCardStyle.secondaryLabel)
                    }
                }
                .lineLimit(1)
                .transition(.opacity)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if minutes != nil {
                            CountingMinutes(value: shownMinutes)
                        } else {
                            Text(text).contentTransition(.numericText())
                        }
                    }
                    .font(Typography.font(28, weight: .semibold))
                    .foregroundStyle(textColor)
                    .tracking(-0.4)
                    if let suffix {
                        Text(suffix)
                            .font(Typography.font(16, weight: .medium))
                            .foregroundStyle(StatusCardStyle.secondaryLabel)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .transition(.opacity)
            }
            GeometryReader { geo in
                let f = max(0, min(1, fraction))
                let w = f > 0 ? max(8, geo.size.width * f) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(HomeStyle.sunk)
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .clipShape(Capsule())
                }
            }
            .frame(height: 8)
        }
        .animation(Self.together, value: fraction)
        .onAppear { if let minutes { shownMinutes = Double(minutes) } }
        .onChange(of: minutes) { old, new in
            guard let new else { return }
            if old == nil {
                // Just opened: count up from nothing, alongside the bar.
                shownMinutes = 0
                DispatchQueue.main.async { withAnimation(Self.together) { shownMinutes = Double(new) } }
            } else {
                withAnimation(Self.together) { shownMinutes = Double(new) }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: color)
        .animation(.easeInOut(duration: 0.4), value: textColor)
        .accessibilityElement(children: .combine)
    }

}

/// A small triangle pointing down.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A time in minutes ("1h 30m") that counts when its value animates.
private struct CountingMinutes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(formatMinutes(Int(value.rounded())))
            .monospacedDigit()
    }
}
