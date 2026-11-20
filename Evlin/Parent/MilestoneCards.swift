import SwiftUI

/// A milestone's own colours: its confetti, and its icon where one shows.
/// None of them green, so a reached goal stops looking like a running one, and
/// none orange.
struct MilestoneLook {
    var card: Color
    var accent: Color

    private static let all: [MilestoneLook] = [
        // Pale by day; deep and muted in Dark, so the light text reads.
        MilestoneLook(card: Color(light: "E8F0FE", dark: "1C2433"), accent: Color(light: "2F6BDE", dark: "7FA6F0")),
        MilestoneLook(card: Color(light: "F1ECFD", dark: "251F33"), accent: Color(light: "6D4BD8", dark: "A893EC")),
        MilestoneLook(card: Color(light: "FDECEA", dark: "331F1D"), accent: Color(light: "D24B3E", dark: "EE8D84")),
        MilestoneLook(card: Color(light: "E3F5F6", dark: "1A2B2D"), accent: Color(light: "0F8A94", dark: "6CC6CD")),
        MilestoneLook(card: Color(light: "FCEBF4", dark: "331E2A"), accent: Color(light: "C93A86", dark: "E98BBE")),
    ]

    /// By the order they were reached, so a child's cards differ from their
    /// neighbours and a card keeps its colours as new ones arrive.
    @MainActor static func of(_ goal: Goal) -> MilestoneLook {
        let earlier = GoalStore.shared.milestones(for: goal.childId)
            .filter { ($0.finishedAt ?? .distantPast) < (goal.finishedAt ?? .distantFuture) }
        return all[earlier.count % all.count]
    }
}

/// The gold of a trophy, and its wooden plinth and shelf.
enum TrophyStyle {
    static let gold = Color(light: "F5B83D", dark: "D9A23C")
    static let goldDark = Color(light: "D9932A", dark: "B57E28")
    static let wood = Color(light: "A47148", dark: "8A5E3C")
    static let woodDark = Color(light: "7A5234", dark: "664630")
}

/// A reached habit as a trophy: a gold cup on a wooden plinth, the habit's own
/// picture on a medallion at its front.
struct TrophyCup: View {
    var goal: Goal
    var size: CGFloat

    var body: some View {
        ZStack {
            Canvas { ctx, canvas in
                ctx.scaleBy(x: canvas.width / 100, y: canvas.height / 100)
                // Handles, then the bowl over them.
                for x in [22.0, 78.0] {
                    var handle = Path()
                    handle.addArc(center: CGPoint(x: x, y: 32), radius: 11,
                                  startAngle: .degrees(x < 50 ? 90 : -90), endAngle: .degrees(x < 50 ? 270 : 90), clockwise: false)
                    ctx.stroke(handle, with: .color(TrophyStyle.goldDark), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                var bowl = Path()
                bowl.move(to: CGPoint(x: 22, y: 16))
                bowl.addLine(to: CGPoint(x: 78, y: 16))
                bowl.addCurve(to: CGPoint(x: 50, y: 64), control1: CGPoint(x: 78, y: 46), control2: CGPoint(x: 66, y: 64))
                bowl.addCurve(to: CGPoint(x: 22, y: 16), control1: CGPoint(x: 34, y: 64), control2: CGPoint(x: 22, y: 46))
                ctx.fill(bowl, with: .color(TrophyStyle.gold))
                ctx.drawLayer { layer in
                    layer.clip(to: bowl)
                    layer.fill(Path(CGRect(x: 58, y: 0, width: 50, height: 100)), with: .color(TrophyStyle.goldDark))
                }
                ctx.fill(Path(roundedRect: CGRect(x: 18, y: 12, width: 64, height: 7), cornerRadius: 3.5), with: .color(TrophyStyle.goldDark))
                ctx.fill(Path(roundedRect: CGRect(x: 45, y: 62, width: 10, height: 12), cornerRadius: 2), with: .color(TrophyStyle.goldDark))
                ctx.fill(Path(roundedRect: CGRect(x: 34, y: 72, width: 32, height: 6), cornerRadius: 3), with: .color(TrophyStyle.gold))
                ctx.fill(Path(roundedRect: CGRect(x: 28, y: 78, width: 44, height: 16), cornerRadius: 3), with: .color(TrophyStyle.wood))
                ctx.fill(Path(roundedRect: CGRect(x: 28, y: 90, width: 44, height: 4), cornerRadius: 2), with: .color(TrophyStyle.woodDark))
            }
            // The medallion with the habit's picture.
            GoalIcon(goal: goal, size: size * 0.2)
                .frame(width: size * 0.3, height: size * 0.3)
                .background(Circle().fill(EColor.card))
                .overlay(Circle().strokeBorder(TrophyStyle.goldDark, lineWidth: max(1.5, size * 0.02)))
                .offset(y: -size * 0.13)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The prize the parent promised, in a small warm pill with a gift.
struct PrizePill: View {
    var prize: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "gift.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TrophyStyle.goldDark)
            // A long prize wraps rather than being cut off.
            Text(prize)
                .font(Typography.font(13, weight: .semibold))
                .foregroundStyle(Neutral.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EColor.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prize: \(prize)")
    }
}

/// A completed milestone (2026-11-07, replacing the Trophy room's trophies):
/// a card in the milestone's own pale colour (`MilestoneLook`) with the
/// habit's picture, the habit, when it was completed, and the prize promised.
/// One under another at the page's full width.
struct CompletedMilestoneCard: View {
    var goal: Goal

    var body: some View {
        let look = MilestoneLook.of(goal)
        HStack(spacing: 12) {
            GoalIcon(goal: goal, size: 28, tint: look.accent)
                .frame(width: 44, height: 44)
                .background(EColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(Typography.font(15.5, weight: .bold))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                if let at = goal.finishedAt {
                    Text("Completed \(at.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(Typography.font(12.5, weight: .medium))
                        .foregroundStyle(Neutral.secondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if !goal.prize.isEmpty {
                PrizePill(prize: goal.prize)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A completed milestone as a ring (2026-11-07): the habit's ring, full and
/// green, its picture inside, the name under it in the rings' style, and
/// when it was completed. Profile's Completed milestones and the completed
/// moment both use it.
struct CompletedMilestoneRing: View {
    var goal: Goal
    var size: CGFloat
    var showsDate = true
    /// Off on the completed moment, which says the days at its top.
    var showsDays = true

    var body: some View {
        VStack(spacing: size * 0.08) {
            ZStack {
                Circle().stroke(GoalRingStyle.green, lineWidth: size * 0.085)
                    .padding(size * 0.0425)
                GoalIcon(goal: goal, size: size * 0.46)
            }
            .frame(width: size, height: size)
            VStack(spacing: 2) {
                GoalRingStyle.name(goal.title)
                // How many days it took, and on Profile when.
                if showsDays || showsDate {
                Text([showsDays ? goal.daysDoneWords : nil,
                      showsDate ? goal.finishedAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) } : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.font(size >= 150 ? 15 : 12, weight: .medium))
                    .foregroundStyle(Neutral.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What's shared: the completed ring on a card, with the child's name and
/// the app's name, drawn to a picture (`ImageRenderer`).
struct MilestoneShareCard: View {
    var goal: Goal
    var childName: String

    var body: some View {
        VStack(spacing: 18) {
            Text("\(childName) completed a habit!")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(Color(hex: "15231A"))
                .multilineTextAlignment(.center)
            CompletedMilestoneRing(goal: goal, size: 220)
            Text("Evlin")
                .font(Typography.font(15, weight: .bold))
                .foregroundStyle(Color(hex: "2FA84F"))
                .padding(.top, 8)
        }
        .padding(40)
        .frame(width: 420)
        .background(Color(hex: "F7F5F0"))
        .environment(\.colorScheme, .light)
    }

    @MainActor static func image(goal: Goal, childName: String) -> Image? {
        let renderer = ImageRenderer(content: MilestoneShareCard(goal: goal, childName: childName))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

/// The milestone's picture big, on its own colour: the completed moment and
/// its sheet (the trophy cup was replaced, 2026-11-07).
struct MilestoneBadge: View {
    var goal: Goal
    var size: CGFloat

    var body: some View {
        let look = MilestoneLook.of(goal)
        GoalIcon(goal: goal, size: size * 0.6, tint: look.accent)
            .frame(width: size, height: size)
            .background(look.card, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Draws nothing. When a goal is reached, plays its moment over whatever's on
/// screen, sheets and story viewer included.
struct MilestoneCelebrationWatcher: View {
    @ObservedObject private var store = GoalStore.shared

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: store.justReached) { _, goal in
                guard let goal else { return }
                let name = FamilyStore.children.first { $0.id == goal.childId }?.name ?? ""
                MilestoneCelebrationWindow.show(goal: goal, childName: name) { store.justReached = nil }
            }
            .task {
                // `-EvlinParentOpen celebrate`: the sample goal that's been reached.
                // `storyreach`: Approve on the check-in that reaches one.
                if DemoMode.parentOpen == "celebrate" {
                    try? await Task.sleep(for: .seconds(1.5))
                    if let goal = store.goals.first(where: { $0.reached && $0.finishedAt == nil }) { store.finish(goal) }
                } else if DemoMode.parentOpen == "storyreach" {
                    try? await Task.sleep(for: .seconds(3))
                    if let goal = store.goals.first(where: { !$0.reached && !$0.waitingToday.isEmpty }), let entry = goal.waitingToday.first {
                        store.review(goal, entry: entry.id, approved: true)
                    }
                }
            }
    }
}

/// Its own window, so it isn't stuck behind a sheet that's closing.
@MainActor
private enum MilestoneCelebrationWindow {
    private static var window: UIWindow?

    static func show(goal: Goal, childName: String, onDone: @escaping () -> Void) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
            onDone()
            return
        }
        let host = UIHostingController(rootView: MilestoneCelebration(goal: goal, look: .of(goal), childName: childName) {
            window?.isHidden = true
            window = nil
            onDone()
        })
        host.view.backgroundColor = .clear
        let new = UIWindow(windowScene: scene)
        new.windowLevel = .alert
        new.backgroundColor = .clear
        // Its own window: take the app's look (Cream or Dark) from the main one.
        new.overrideUserInterfaceStyle = scene.windows.first(where: { $0 !== new })?.overrideUserInterfaceStyle ?? .unspecified
        new.rootViewController = host
        new.isHidden = false
        window = new
    }
}

/// A goal reached: congratulations to the parent, its trophy with a burst of
/// confetti, then what's next: another good habit, or this one again with a
/// different prize. Either way the trophy shrinks into the Profile tab.
private struct MilestoneCelebration: View {
    var goal: Goal
    var look: MilestoneLook
    var childName: String
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var leaving = false
    /// Keep going: the moment lifts away and dissolves into New habit,
    /// already rising underneath (not the shrink into Profile).
    @State private var forward = false

    /// "read for 20 minutes": the habit's idea in the past, if it has one
    /// (a renamed one is the parent's own words, so it's left out).
    private var didIt: String? {
        guard goal.picture == nil || goal.picture == goal.title else { return nil }
        return GoalIdea.didIt[goal.title]
    }
    @State private var burstStart: Date?

    var body: some View {
        GeometryReader { geo in
            // The Profile tab, last of the three, at the bottom of the screen.
            let toTab = CGSize(width: geo.size.width * 0.21, height: geo.size.height / 2 - 40)
            ZStack {
                // Fully covers the screen: what's under it doesn't show through.
                Rectangle().fill(EColor.surface).opacity(shown && !leaving && !forward ? 1 : 0)
                    .ignoresSafeArea()
                if let burstStart, !reduceMotion {
                    MilestoneConfetti(start: burstStart, colors: [look.accent, look.card, Color(hex: "F5B83D"), Color(hex: "6D8BF0")])
                        .ignoresSafeArea()
                }
                VStack(spacing: 14) {
                    // A habit picked from the ideas: what the child did, in
                    // words, under Congratulations ("Mia read for 20 minutes
                    // for 6 days."). One the parent typed: the days in a
                    // green pill at the top, and "Mia reached …" (2026-11-08).
                    if didIt == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 15, weight: .bold))
                            Text(goal.daysDoneWords)
                                .font(Typography.font(17, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(FormGreen.accent)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(FormGreen.accentBg, in: Capsule())
                        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                        .opacity(shown && !leaving && !forward ? 1 : 0)
                        .padding(.bottom, 2)
                    }
                    Text("Congratulations!")
                        .font(Typography.font(28, weight: .heavy))
                        .foregroundStyle(Neutral.ink)
                        .opacity(shown && !leaving && !forward ? 1 : 0)
                    Text(didIt.map { "\(childName) \($0) for \(goal.daysDoneWords)." } ?? "\(childName) reached \(goal.title).")
                        .font(Typography.font(16, weight: .medium))
                        .foregroundStyle(Neutral.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .opacity(shown && !leaving && !forward ? 1 : 0)
                    CompletedMilestoneRing(goal: goal, size: 170, showsDate: false, showsDays: false)
                        .scaleEffect(forward ? (reduceMotion ? 1 : 1.12) : leaving ? (reduceMotion ? 1 : 0.14) : (shown || reduceMotion ? 1 : 0.8))
                        .offset(forward ? CGSize(width: 0, height: reduceMotion ? 0 : -60) : (leaving && !reduceMotion ? toTab : .zero))
                        .opacity(forward || (leaving && reduceMotion) ? 0 : (shown ? 1 : 0))
                    // What's next: another good habit, or this one again
                    // with a different prize (2026-11-06; the prize isn't
                    // repeated here).
                    // Two even buttons: the next habit and Share, then Maybe
                    // later (2026-11-07; "Keep going with a new prize" and a
                    // small Not now were dropped).
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            Button { keepGoing() } label: {
                                Label("Keep going", systemImage: "arrow.right")
                                    .font(Typography.font(16, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 16))
                            }
                            if let picture = MilestoneShareCard.image(goal: goal, childName: childName) {
                                ShareLink(item: picture,
                                          preview: SharePreview("\(childName) completed \(goal.title)", image: picture)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .font(Typography.font(17, weight: .bold))
                                        .foregroundStyle(Neutral.ink)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 54)
                                        .background(EColor.card, in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Neutral.border, lineWidth: 1))
                                }
                            }
                        }
                        Button { leave() } label: {
                            Text("Maybe later")
                                .font(Typography.font(17, weight: .semibold))
                                .foregroundStyle(Neutral.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .opacity(shown && !leaving && !forward ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) { shown = true }
            burstStart = Date()
        }
    }

    /// Keep going: the moment lifts a little and dissolves, and New habit
    /// rises straight after (2026-11-08: the ring
    /// shrinking into Profile and then the form opening read as two endings).
    private func keepGoing() {
        guard !leaving, !forward else { return }
        withAnimation(.easeOut(duration: 0.4)) { forward = true }
        Task {
            // New habit can't open under this window (it's above everything),
            // so it rises the moment the window goes.
            try? await Task.sleep(for: .seconds(0.3))
            onDone()
            GoalStore.shared.nextHabit = NextHabit(childId: goal.childId, again: nil)
        }
    }

    /// The trophy shrinks into the Profile tab; then New habit opens if the
    /// parent chose what's next.
    private func leave(then next: NextHabit? = nil) {
        guard !leaving else { return }
        withAnimation(.easeInOut(duration: 0.55)) { leaving = true }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            onDone()
            if let next { GoalStore.shared.nextHabit = next }
        }
    }
}

/// One burst from the middle of the screen, falling away and fading.
private struct MilestoneConfetti: View {
    var start: Date
    var colors: [Color]

    private struct Piece {
        var angle, speed, spin, size: Double
        var color: Int
    }

    private static let pieces: [Piece] = (0..<44).map { i in
        // Spread evenly, varied by fixed steps: the same burst every time.
        let v = Double((i * 37) % 44) / 44
        return Piece(angle: Double(i) / 44 * 2 * .pi, speed: 230 + 300 * v, spin: 3 + 8 * v, size: 6 + 5 * v, color: i)
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSince(start)
                guard t < 2.2 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                canvas.opacity = min(1, max(0, (2.2 - t) / 0.7))
                for p in Self.pieces {
                    // Quick to leave, then slowing, then gravity takes over.
                    let travel = p.speed * (1 - exp(-2.6 * t)) / 2.6 * 1.6
                    let x = center.x + cos(p.angle) * travel
                    let y = center.y + sin(p.angle) * travel + 170 * t * t
                    var piece = canvas
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(p.spin * t))
                    let rect = CGRect(x: -p.size / 2, y: -p.size * 0.3, width: p.size, height: p.size * 0.6)
                    piece.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colors[p.color % colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
