import SwiftUI

/// New habit's prize tip (2026-11-14, the user's call: real prizes are what
/// make habits work): the first time an idea's set-up opens, its prizes are
/// lit with a card (`TourSpotlight`), until Got it. Home's Habits tab was
/// pointed out too the same day, a dimmed page with a card, then a glowing
/// ring round the tab; both were removed at the user's call.
enum HabitsTour {
    /// Got it on the prizes' card.
    static let prizeTipKey = "evlin.habitsPrizeTipDone"
}

/// The page dimmed with one thing cut out, a soft ring breathing round it,
/// and a card with its tip pointing at it: under it when there's room,
/// else over it.
struct TourSpotlight<Card: View>: View {
    /// The lit thing's frame, in global coordinates.
    var target: CGRect
    var pad: CGFloat = 10
    /// The card over what's lit, whatever room there is under it.
    var above = false
    /// The card's widest (the iPad's: a phone's is the page's width).
    var cardWidth: CGFloat = .infinity
    @ViewBuilder var card: Card

    @State private var breathe = false
    @State private var cardHeight: CGFloat = 200

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            let hole = target.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -pad, dy: -pad)
            let radius = min(18, hole.height / 2)
            let below = !above && hole.maxY + 20 + cardHeight < g.size.height - 24
            let side: CGFloat = 24
            let width = min(g.size.width - side * 2, cardWidth)
            // Under (or over) what's lit, kept on the page.
            let cardX = min(max(hole.midX - width / 2, side), g.size.width - side - width)
            let tipX = min(max(hole.midX - cardX, 34), width - 34)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .stroke(Color.white.opacity(breathe ? 0.10 : 0.28), lineWidth: 2)
                    .frame(width: hole.width + (breathe ? 14 : 2), height: hole.height + (breathe ? 14 : 2))
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
                card
                    .frame(width: width)
                    .background(TourCardShape(tipX: tipX, down: !below).fill(EColor.card))
                    .overlay(TourCardShape(tipX: tipX, down: !below).stroke(HomeStyle.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .offset(x: cardX, y: below ? hole.maxY + 20 : hole.minY - 20 - cardHeight)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// A tour card's words: a title and a line or two, centred, then its buttons.
struct TourCard<Buttons: View>: View {
    var title: String
    var words: String
    /// The kid's iPad: bigger words.
    var big = false
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: big ? 10 : 8) {
            Text(title)
                .font(Typography.font(big ? 26 : 19, weight: .semibold))
                .foregroundStyle(EColor.onSurface)
            Text(words)
                .font(Typography.font(big ? 20 : 15.5, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(EColor.onSurface.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            buttons
                .buttonStyle(CardPressStyle(haptic: true))
                .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, big ? 28 : 20)
        .padding(.top, big ? 28 : 22)
        .padding(.bottom, big ? 22 : 18)
        .frame(maxWidth: .infinity)
    }
}

struct TourButton: View {
    var title: String
    var primary: Bool
    /// The primary's green: the main app's, or the kid's (`KidTheme.paperButton`).
    var tint: Color = FormGreen.accent
    var big = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(big ? 20 : 15.5, weight: .semibold))
                .foregroundStyle(primary ? .white : EColor.onSurface)
                .frame(maxWidth: .infinity, minHeight: big ? 58 : 46)
                .background(primary ? tint : HomeStyle.sunk, in: Capsule())
        }
    }
}

/// A rounded card with a small tip at `tipX`, pointing up (or down, for a
/// card over what it's about).
private struct TourCardShape: Shape {
    var tipX: CGFloat
    var down: Bool

    func path(in r: CGRect) -> Path {
        let radius: CGFloat = 18, tipW: CGFloat = 22, tipH: CGFloat = 10
        var p = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
        let x = r.minX + tipX
        let edge = down ? r.maxY - 0.5 : r.minY + 0.5
        let s: CGFloat = down ? 1 : -1
        p.move(to: CGPoint(x: x - tipW / 2, y: edge))
        p.addLine(to: CGPoint(x: x - 3, y: edge + s * (tipH - 2)))
        p.addQuadCurve(to: CGPoint(x: x + 3, y: edge + s * (tipH - 2)),
                       control: CGPoint(x: x, y: edge + s * (tipH + 1)))
        p.addLine(to: CGPoint(x: x + tipW / 2, y: edge))
        p.closeSubpath()
        return p
    }
}

/// After the first habit is added (2026-11-16, the user's call), a shadow
/// tour on its ring on Home's Habits lane: the child holds the ring on their
/// device to say it's done, and the parent approves (a third card, holding
/// the ring to count it by hand, was removed with that, 2026-11-16). Once per phone. Over the whole app (`ParentRootView`), the
/// tab bar hidden meanwhile.
@MainActor
final class HabitTour: ObservableObject {
    static let shared = HabitTour()
    /// Set once the tour's been seen.
    static let doneKey = "evlin.habitTourDone"
    /// The habit it's shown on: set by Add habit until then.
    static let pendingKey = "evlin.habitTourGoal"

    enum Step: Int, CaseIterable { case checkIn, approve }

    @Published private(set) var step: Step?
    @Published private(set) var ring: CGRect?
    private(set) var childName = ""
    private(set) var habit = ""

    /// Add habit: the tour waits for this habit's ring, unless it's been seen.
    static func habitAdded(_ goal: Goal) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        UserDefaults.standard.set(goal.id, forKey: pendingKey)
    }

    /// The ring on screen, or nil when it's gone (another lane, a sheet over it).
    func show(_ ring: CGRect?, childName: String, habit: String) {
        guard ring != nil || step != nil else { return }
        self.childName = childName
        self.habit = habit
        if let ring {
            if step == nil { withAnimation(.easeOut(duration: 0.35)) { step = Step(rawValue: DemoMode.habitTourStep) ?? .checkIn } }
            self.ring = ring
        } else {
            withAnimation(.easeOut(duration: 0.25)) { self.ring = nil }
        }
    }

    func next() {
        guard let step else { return }
        if let after = Step(rawValue: step.rawValue + 1) {
            withAnimation(.easeOut(duration: 0.3)) { self.step = after }
        } else {
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            withAnimation(.easeOut(duration: 0.3)) { self.step = nil; ring = nil }
        }
    }

    var showing: Bool { step != nil && ring != nil }

    var title: String {
        switch step {
        case .checkIn, nil: "\(childName) says when it's done"
        case .approve: "You approve"
        }
    }

    var words: String {
        switch step {
        case .checkIn, nil: "Each time \(childName) does “\(habit)”, a press and hold on \(childName)’s device sends it to you. The ring turns orange here."
        case .approve: "When it turns orange, tap the ring and approve. Each approval fills it a step toward the prize."
        }
    }
}

/// The habit tour itself, over the whole app (`ParentRootView`).
struct HabitTourView: View {
    @ObservedObject private var tour = HabitTour.shared

    var body: some View {
        if let step = tour.step, let ring = tour.ring {
            TourSpotlight(target: ring, pad: 12, cardWidth: 460) {
                TourCard(title: tour.title, words: tour.words) {
                    TourButton(title: step == .approve ? "Got it" : "Next", primary: true) { tour.next() }
                }
            }
            .id(step)
            .transition(.opacity)
        }
    }
}
