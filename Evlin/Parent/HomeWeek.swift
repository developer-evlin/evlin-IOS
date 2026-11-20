import SwiftUI

/// What's planned for a child on `day`: today's live list (with its
/// states), tomorrow's, or any later day's from the tasks' own repeat rules
/// (Home's This week, the chore picker's preview).
@MainActor
func plannedTasks(childId: String, on day: Date) -> [ChildTask] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    if cal.isDate(day, inSameDayAs: today) {
        return TaskStore.tasks(for: childId).filter(\.isDueToday)
    }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: today), cal.isDate(day, inSameDayAs: tomorrow) {
        return TaskStore.tomorrowTasks(for: childId)
    }
    return CalendarSync.tasks(from: LocalStore.shared.cachedTasksByChild()[childId] ?? [], on: day)
}

// MARK: - Goals

/// A goal ring's colours and its name under it, on both sides: a grey ring, the
/// same green as Home's progress bar going round inside it, and black for the
/// icon, number and name. With nothing done the ring is only grey.
enum GoalRingStyle {
    static let green = StatusCardStyle.green
    /// The grey ring, a step deeper than the hairlines so it holds on the
    /// Alabaster page (2026-11-14; Neutral.line, #E5E1D9, faded into it).
    static let track = Color(light: "E5E5EA", dark: "353A42", warm: "353A42")
    static let label = EColor.onSurface
    /// Home's Goals lane: big enough that four fill the page down to the +.
    // 112 (2026-11-07): at 136 four habits and the floating + didn't fit.
    static let homeSize: CGFloat = 112
    /// A ring waiting for the parent: a warm, soft orange.
    static let waiting = Color(light: "F2AE6C", dark: "C48A52")
    /// The badge on a waiting ring: a step deeper, so the white hand reads.
    static let waitingBadge = Color(light: "E8964A", dark: "B87B44")
    static let homeLine: CGFloat = 10

    static func name(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.font(13, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(label)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }
}

/// A goal's ring: the goal's icon in one continuous grey ring, filling green, and
/// from `numberFrom` up just the number left under it, as in Streaks. A check-in
/// waiting for approval follows in paler green. For the parent, who has to answer
/// it, the number pulses slightly; for the kid, who waits, the pale part fades.
struct GoalRing: View {
    var goal: Goal
    var size: CGFloat
    var line: CGFloat
    /// The kid's side: the number counts today's check-in as soon as it's sent.
    var countsWaiting = false
    /// Waiting for the parent: a small orange badge with a tapping hand on
    /// the ring's shoulder, like an app's notification badge (off in the half
    /// card, where Approve is right there).
    var marksWaiting = true
    /// The kid's side, sent in: the ring turns the parent's soft orange while
    /// it waits (2026-11-16, the user's call; a pale green fading before).
    var waitsOrange = false

    private static let numberFrom: CGFloat = 100

    // What's approved stays. Today's check-ins waiting follow it.
    private var waitingEnd: Double {
        goal.target > 0 ? min(1, goal.fraction + Double(goal.waitingToday.count) / Double(goal.target)) : 0
    }
    private var left: Int { max(0, goal.target - goal.done - (countsWaiting ? goal.waitingToday.count : 0)) }

    var body: some View {
        let showsNumber = size >= Self.numberFrom
        let needsParent = !countsWaiting && !goal.waitingToday.isEmpty
        let orange = !goal.waitingToday.isEmpty && (!countsWaiting || waitsOrange)
        ZStack {
            ZStack {
                Circle().stroke(GoalRingStyle.track, lineWidth: line)
                // The parent's side, checked in today: the ring turns a soft
                // orange and glows gently, so it says "tap me" (2026-11-07;
                // a paler green arc and an Approve pill under it were tried).
                if orange { GoalRingGlow(line: line).transition(.opacity) }
                if !goal.waitingToday.isEmpty {
                    if countsWaiting && !orange {
                        GoalRingWaitingArc(progress: waitingEnd, line: line)
                    } else {
                        GoalRingArc(progress: waitingEnd, color: GoalRingStyle.waiting.opacity(0.45), line: line)
                    }
                }
                GoalRingArc(progress: goal.fraction, color: orange ? GoalRingStyle.waiting : GoalRingStyle.green, line: line)
            }
            .padding(line / 2)
            if HabitArt.has(goal.pictureKey) {
                HabitArt(title: goal.pictureKey)
                    .frame(width: size * (showsNumber ? 0.42 : 0.62), height: size * (showsNumber ? 0.42 : 0.62))
                    .offset(y: showsNumber ? -size * 0.1 : 0)
            } else if goal.symbol == Goal.leafSymbol {
                HabitLeaf()
                    .frame(width: size * (showsNumber ? 0.38 : 0.58), height: size * (showsNumber ? 0.38 : 0.58))
                    .offset(y: showsNumber ? -size * 0.1 : 0)
            } else {
                Image(systemName: goal.symbol)
                    .font(.system(size: size * (showsNumber ? 0.25 : 0.3), weight: .semibold))
                    .foregroundStyle(GoalRingStyle.label)
                    .offset(y: showsNumber ? -size * 0.09 : 0)
            }
            if showsNumber {
                GoalRingNumber(left: left, size: size, pulses: needsParent)
                    .offset(y: size * 0.17)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if needsParent && marksWaiting && size >= Self.numberFrom {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: size * 0.11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .background(GoalRingStyle.waitingBadge, in: Circle())
                    .overlay(Circle().strokeBorder(EColor.surface, lineWidth: 2.5))
                    .offset(x: -size * 0.02, y: size * 0.02)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        // Approved or sent back: the orange eases into green (or grey).
        .animation(.easeInOut(duration: 0.55), value: orange)
        .animation(.easeOut(duration: 0.2), value: goal.done)
        .animation(.easeOut(duration: 0.2), value: goal.waitingToday.count)
    }
}

/// A soft orange halo round a ring waiting for the parent, breathing slowly.
private struct GoalRingGlow: View {
    var line: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Circle()
            .stroke(GoalRingStyle.waiting, lineWidth: line)
            .blur(radius: line * 0.7)
            .opacity(bright ? 0.3 : 0.08)
            .onAppear {
                guard !reduceMotion else { bright = true; return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// The number left, in a ring. Slowly growing and settling when `pulses`.
private struct GoalRingNumber: View {
    var left: Int
    var size: CGFloat
    var pulses: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let beat = 1.8

    private var number: some View {
        Text("\(left)")
            .font(Typography.font(size * 0.14, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(GoalRingStyle.label)
            .contentTransition(.numericText(value: Double(left)))
    }

    var body: some View {
        if pulses && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.beat)
                number.scaleEffect(1 + 0.16 * (1 - cos(t / Self.beat * 2 * .pi)) / 2)
            }
        } else {
            number
        }
    }
}

/// The ring's filled part: one unbroken line from the top, round at its ends.
struct GoalRingArc: View {
    var progress: Double
    var color: Color
    var line: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// The kid's side of a ring waiting for approval: pale green, slowly fading in
/// and out. Slow and only this part, so a screen of them stays easy on the eyes.
struct GoalRingWaitingArc: View {
    var progress: Double
    var line: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let breath = 4.0

    var body: some View {
        if reduceMotion {
            GoalRingArc(progress: progress, color: GoalRingStyle.green.opacity(0.4), line: line)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.breath)
                let level = (1 - cos(t / Self.breath * 2 * .pi)) / 2
                GoalRingArc(progress: progress, color: GoalRingStyle.green.opacity(0.28 + 0.24 * level), line: line)
            }
        }
    }
}

/// Home's Goals lane under four goals: the next goal's place, after the last ring.
struct GoalAddCell: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().stroke(GoalRingStyle.track, lineWidth: GoalRingStyle.homeLine).padding(GoalRingStyle.homeLine / 2)
                    Image(systemName: "plus")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(GoalRingStyle.label)
                }
                .frame(width: GoalRingStyle.homeSize, height: GoalRingStyle.homeSize)
                GoalRingStyle.name("Add habit")
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Home's Goals lane with no goals at all. Each time it opens, brown earth rises
/// in the bottom of the ring and a young plant shoots up out of it, quick to open
/// its two sweeping leaves and a small sprout at the side. The shadow spreads on the ground, then it keeps growing slowly for as long as the screen is open, the ring
/// filling with it. The button's arrow nudges forward.
/// Everything runs off one clock.
struct GoalsEmptyStart: View {
    var action: () -> Void
    /// Off: just the growing plant in its ring (the kid's All set!, 2026-11-09).
    var wordsShown = true
    var plantSize: CGFloat = 186
    /// The page behind it: the wind's parting line between the leaves.
    var gap: Color = EColor.surface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = Date()

    private static let size: CGFloat = 186
    private static let line: CGFloat = 10

    // The ring, 0 to 1: most of it in the first moment, then ever more slowly.
    private func ringFilled(_ t: Double) -> Double {
        0.62 * (1 - exp(-t / 0.3)) + 0.38 * (1 - exp(-t / 16))
    }

    // 0 to 1 from `start`: under half in the first moment, so there's plenty of
    // growing still to see.
    private func grown(_ t: Double, from start: Double) -> Double {
        let t = max(0, t - start)
        return 0.42 * (1 - exp(-t / 0.3)) + 0.58 * (1 - exp(-t / 16))
    }

    // A gust of wind, 0 to 1 and back, every few seconds once the plant is up.
    private func wind(_ t: Double) -> Double {
        guard !reduceMotion, t > 1.2 else { return 0 }
        let phase = (t - 1.2).truncatingRemainder(dividingBy: 4.5) / 2.7
        guard phase < 1 else { return 0 }
        return pow(sin(phase * .pi), 2)
    }

    // A leaf: out almost at once, then a little more over time.
    private func leafOut(_ t: Double, from start: Double) -> Double {
        guard t > start else { return 0 }
        let t = t - start
        return 0.72 * (1 - exp(-t / 0.14)) + 0.28 * (1 - exp(-t / 16))
    }

    private func appeared(_ t: Double, after start: Double) -> Double {
        let x = min(1, max(0, (t - start) / 0.4))
        return x * x * (3 - 2 * x)
    }

    var body: some View {
        Group {
            if reduceMotion {
                content(60)
            } else {
                TimelineView(.animation) { context in
                    content(context.date.timeIntervalSince(opened))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, wordsShown ? 36 : 0)
        .onAppear { opened = Date() }
    }

    private func content(_ t: Double) -> some View {
        let words = appeared(t, after: 0.55)
        return VStack(spacing: 16) {
            Button(action: action) { plant(t) }
                .buttonStyle(CardPressStyle())
                .accessibilityHidden(true)
            if wordsShown {
            Text("Start building habits")
                .font(Typography.font(21, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
                .offset(y: 14 * (1 - words))
                .opacity(words)
            beginButton(t)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .offset(y: 14 * (1 - words))
                .opacity(words)
            }
        }
    }

    // The plant, rising out of the earth and swaying as it grows: the stem
    // first, its leaves quick behind it, the shadow on the ground growing with
    // them. Everything's drawn on the ring's inner 130 square.
    private func plant(_ t: Double) -> some View {
        let root = UnitPoint(x: 61 / 130, y: 100 / 130)
        let size = grown(t, from: 0)
        let gust = wind(t)
        return ZStack {
            Circle().stroke(GoalRingStyle.track, lineWidth: Self.line)
            Circle()
                .trim(from: 0, to: ringFilled(t))
                .stroke(GoalRingStyle.green, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(90))
            ZStack {
                ZStack {
                    SproutStem()
                        .trim(from: 0, to: min(1, t / 0.3))
                        .stroke(SproutColor.stem, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    SproutSideStem()
                        .trim(from: 0, to: appeared(t, after: 0.3))
                        .stroke(SproutColor.stem, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    sproutPart(from: UnitPoint(x: 56 / 130, y: 82 / 130), out: leafOut(t, from: 0.4)) {
                        SproutSideLeaf().fill(SproutColor.leaf)
                    }
                    sproutPart(from: UnitPoint(x: 62 / 130, y: 64 / 130), out: leafOut(t, from: 0.2), turn: -4 * gust) {
                        SproutTopLeaf().fill(SproutColor.leaf)
                        SproutTopLeafShade().fill(SproutColor.shade)
                    }
                    sproutPart(from: UnitPoint(x: 64 / 130, y: 66 / 130), out: leafOut(t, from: 0.3), turn: 13 * gust) {
                        // Still, the two read as one whole leaf. The wind parts
                        // them, and this edge keeps the split clean.
                        SproutLowerLeaf().stroke(gap, lineWidth: 2 * gust)
                        SproutLowerLeaf().fill(SproutColor.leaf)
                        SproutLowerLeafShade().fill(SproutColor.shade)
                    }
                }
                .frame(width: 130, height: 130)
                .scaleEffect(0.8 + 0.2 * size, anchor: root)
                .rotationEffect(.degrees(1.5 * sin(t * 1.4) + 2.5 * gust), anchor: root)

                // The earth, in front of where the stems come out of it.
                SproutEarth(rise: 40 * (1 - appeared(t, after: 0)))
                // The plant's shadow on it.
                Ellipse()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 8 + 30 * size, height: 3 + 3 * size)
                    .blur(radius: 2)
                    .position(x: 63 + 5 * size, y: 99)
                    .opacity(appeared(t, after: 0.1))
            }
            .frame(width: 130, height: 130)
            .clipShape(Circle())
        }
        .padding(Self.line / 2)
        .frame(width: 150, height: 150)
        .scaleEffect(plantSize / 150)
        .frame(width: plantSize, height: plantSize)
    }

    // A leaf, opening from where it joins its stem.
    private func sproutPart<Part: View>(from base: UnitPoint, out: Double, turn: Double = 0, @ViewBuilder part: () -> Part) -> some View {
        ZStack { part() }
            .frame(width: 130, height: 130)
            .scaleEffect(max(0.001, out), anchor: base)
            .rotationEffect(.degrees(turn), anchor: base)
    }

    // The arrow nudges forward, again and again.
    private func beginButton(_ t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
        let nudge = max(0, sin(phase * 2 * .pi * 2)) * 5
        return Button(action: action) {
            HStack(spacing: 8) {
                Text("Tap to begin")
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .heavy))
                    .offset(x: nudge)
            }
            .font(Typography.font(16, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: FormGreen.accent.opacity(0.3), radius: 12, y: 6)
        }
        .buttonStyle(CardPressStyle())
    }
}

/// A habit's picture wherever it stands alone (Milestones): its drawing,
/// our leaf, or else its symbol in `tint`.
struct GoalIcon: View {
    var goal: Goal
    var size: CGFloat
    var tint: Color = Neutral.ink

    var body: some View {
        if HabitArt.has(goal.pictureKey) {
            HabitArt(title: goal.pictureKey).frame(width: size, height: size)
        } else if goal.symbol == Goal.leafSymbol {
            HabitLeaf().frame(width: size, height: size)
        } else {
            Image(systemName: goal.symbol)
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// A habit's own leaf, for one with no picture or better icon: our split
/// leaf as the growing plant draws it (the user liked it there), still and
/// friendly: the two leaves in soft flat greens, parted a little so the split
/// shows, on a short curved stem. The logo's dark gradients and drawn
/// single leaves were tried (2026-11-05).
struct HabitLeaf: View {
    private static let leaf = Color(light: "5DD37A", dark: "4CB467")
    private static let shade = Color(light: "3DB45E", dark: "349552")
    private static let stem = Color(light: "3BA554", dark: "33884A")

    var body: some View {
        GeometryReader { geo in
            // The leaves and a short stem fill about 56 x 72 of the plant's 130.
            let scale = min(geo.size.width, geo.size.height) / 76
            ZStack {
                StemShort().stroke(Self.stem, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                ZStack {
                    SproutTopLeaf().fill(Self.leaf)
                    SproutTopLeafShade().fill(Self.shade)
                }
                ZStack {
                    SproutLowerLeaf().stroke(EColor.surface, lineWidth: 3)
                    SproutLowerLeaf().fill(Self.leaf)
                    SproutLowerLeafShade().fill(Self.shade)
                }
                .rotationEffect(.degrees(9), anchor: UnitPoint(x: 64 / 130, y: 66 / 130))
            }
            .frame(width: 130, height: 130)
            .offset(x: 65 - 73, y: 65 - 50)
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    /// The stem, short: just out from under the leaves.
    private struct StemShort: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 60, y: 86))
            p.addCurve(to: CGPoint(x: 64, y: 64), control1: CGPoint(x: 59, y: 78), control2: CGPoint(x: 59, y: 70))
            return p
        }
    }
}

// The empty Goals plant, on the ring's inner 130 square.
private enum SproutColor {
    static let leaf = Color(light: "4CC764", dark: "3FA457")
    static let shade = Color(light: "2E9E4F", dark: "2A7F41")
    static let stem = Color(light: "2F8F46", dark: "2B7A3D")
}

/// The main stem, up out of the earth to the two big leaves.
private struct SproutStem: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 62, y: 102))
        p.addCurve(to: CGPoint(x: 64, y: 64), control1: CGPoint(x: 59, y: 88), control2: CGPoint(x: 59, y: 76))
        return p
    }
}

/// The little stem off to the side, to the sprout.
private struct SproutSideStem: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 60, y: 88))
        p.addQuadCurve(to: CGPoint(x: 54, y: 80), control: CGPoint(x: 58, y: 83))
        return p
    }
}

/// The small sprout's leaf.
private struct SproutSideLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 56, y: 82))
        p.addCurve(to: CGPoint(x: 44, y: 70), control1: CGPoint(x: 49, y: 83), control2: CGPoint(x: 44, y: 78))
        p.addCurve(to: CGPoint(x: 56, y: 82), control1: CGPoint(x: 52, y: 70), control2: CGPoint(x: 58, y: 74))
        p.closeSubpath()
        return p
    }
}

/// The top leaf: an S sweeping up to a point at the top right.
private struct SproutTopLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 62, y: 64))
        p.addCurve(to: CGPoint(x: 68, y: 32), control1: CGPoint(x: 52, y: 50), control2: CGPoint(x: 58, y: 38))
        p.addCurve(to: CGPoint(x: 84, y: 13), control1: CGPoint(x: 76, y: 27), control2: CGPoint(x: 82, y: 22))
        p.addCurve(to: CGPoint(x: 84, y: 42), control1: CGPoint(x: 93, y: 22), control2: CGPoint(x: 94, y: 34))
        p.addCurve(to: CGPoint(x: 62, y: 64), control1: CGPoint(x: 78, y: 47), control2: CGPoint(x: 70, y: 52))
        p.closeSubpath()
        return p
    }
}

/// The darker side of the top leaf.
private struct SproutTopLeafShade: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 84, y: 13))
        p.addCurve(to: CGPoint(x: 84, y: 42), control1: CGPoint(x: 93, y: 22), control2: CGPoint(x: 94, y: 34))
        p.addCurve(to: CGPoint(x: 62, y: 64), control1: CGPoint(x: 78, y: 47), control2: CGPoint(x: 70, y: 52))
        p.addCurve(to: CGPoint(x: 81, y: 36), control1: CGPoint(x: 67, y: 50), control2: CGPoint(x: 76, y: 44))
        p.addCurve(to: CGPoint(x: 84, y: 13), control1: CGPoint(x: 85, y: 30), control2: CGPoint(x: 86, y: 22))
        p.closeSubpath()
        return p
    }
}

/// The second leaf, tucked close under the top one, sweeping up to the right.
private struct SproutLowerLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 64, y: 66))
        p.addCurve(to: CGPoint(x: 80, y: 42), control1: CGPoint(x: 65, y: 55), control2: CGPoint(x: 73, y: 47))
        p.addCurve(to: CGPoint(x: 92, y: 28), control1: CGPoint(x: 86, y: 38), control2: CGPoint(x: 90, y: 34))
        p.addCurve(to: CGPoint(x: 84, y: 57), control1: CGPoint(x: 98, y: 39), control2: CGPoint(x: 93, y: 51))
        p.addCurve(to: CGPoint(x: 64, y: 66), control1: CGPoint(x: 77, y: 62), control2: CGPoint(x: 70, y: 62))
        p.closeSubpath()
        return p
    }
}

/// The darker side of the second leaf.
private struct SproutLowerLeafShade: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 92, y: 28))
        p.addCurve(to: CGPoint(x: 84, y: 57), control1: CGPoint(x: 98, y: 39), control2: CGPoint(x: 93, y: 51))
        p.addCurve(to: CGPoint(x: 64, y: 66), control1: CGPoint(x: 77, y: 62), control2: CGPoint(x: 70, y: 62))
        p.addCurve(to: CGPoint(x: 83, y: 49), control1: CGPoint(x: 71, y: 58), control2: CGPoint(x: 78, y: 55))
        p.addCurve(to: CGPoint(x: 92, y: 28), control1: CGPoint(x: 88, y: 44), control2: CGPoint(x: 91, y: 36))
        p.closeSubpath()
        return p
    }
}

/// The earth: a lumpy mound with a few darker clods.
private struct SproutEarth: View {
    var rise: CGFloat

    var body: some View {
        ZStack {
            SproutMound()
                .fill(LinearGradient(colors: [Color(light: "9A6238", dark: "A47552"), Color(light: "7A4A28", dark: "85593A")], startPoint: .top, endPoint: .bottom))
            ForEach(Self.clods.indices, id: \.self) { i in
                let c = Self.clods[i]
                Ellipse()
                    .fill(Color(light: "5E3719", dark: "6E4630"))
                    .frame(width: c.2, height: c.2 * 0.62)
                    .position(x: c.0, y: c.1)
            }
        }
        .frame(width: 130, height: 130)
        .offset(y: rise)
    }

    private static let clods: [(CGFloat, CGFloat, CGFloat)] = [
        (43, 111, 6), (53, 106, 2.5), (72, 104, 5), (88, 108, 3), (94, 112, 4.5), (83, 115, 2.5),
    ]
}

private struct SproutMound: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 108))
        p.addCurve(to: CGPoint(x: 42, y: 102), control1: CGPoint(x: 14, y: 106), control2: CGPoint(x: 30, y: 105))
        p.addCurve(to: CGPoint(x: 62, y: 95), control1: CGPoint(x: 48, y: 97), control2: CGPoint(x: 55, y: 95))
        p.addCurve(to: CGPoint(x: 78, y: 98), control1: CGPoint(x: 68, y: 94), control2: CGPoint(x: 74, y: 95))
        p.addCurve(to: CGPoint(x: 92, y: 102), control1: CGPoint(x: 82, y: 97), control2: CGPoint(x: 88, y: 99))
        p.addCurve(to: CGPoint(x: 130, y: 108), control1: CGPoint(x: 104, y: 104), control2: CGPoint(x: 118, y: 106))
        p.addLine(to: CGPoint(x: 130, y: 170))
        p.addLine(to: CGPoint(x: 0, y: 170))
        p.closeSubpath()
        return p
    }
}

/// How a check-in stands, in words and a colour, for both sides.
enum CheckInLook {
    static func word(_ s: GoalCheckIn.Status) -> String {
        switch s {
        case .waiting: return "Waiting"
        case .approved: return "Counted"
        case .notApproved: return "Redo asked"
        }
    }
    static func color(_ s: GoalCheckIn.Status) -> Color {
        switch s {
        case .waiting: return Neutral.secondary
        case .approved: return HomeStyle.green
        case .notApproved: return HomeStyle.waiting
        }
    }
    static func when(_ d: Date) -> String {
        let day = Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday"
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day), \(d.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - One goal

/// A goal opened by the parent: its ring, the prize, and today's check-ins to
/// answer. Its details change in New goal's form (Edit goal).
struct GoalSheet: View {
    var goalId: String
    var childName: String
    @ObservedObject private var store = GoalStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var countedTick = 0
    @State private var redoTick = 0
    @State private var editing = false
    @State private var saved = false
    /// Answered here: true approved, false sent back. The card holds still
    /// (same chip, same buttons, the pressed one marked) while the ring
    /// turns, then closes by itself: it doesn't swap to Edit habit under
    /// the parent's finger.
    @State private var answered: Bool? = nil
    @State private var heldEntry: GoalCheckIn? = nil

    var body: some View {
        if let goal = store.goals.first(where: { $0.id == goalId }) {
            // A half card. A check-in waiting: just Approve, with a pen to
            // edit. Nothing waiting: Edit goal, where deleting it lives too.
            let waiting = answered != nil ? heldEntry : goal.waitingToday.min { $0.at < $1.at }
            VStack(spacing: 0) {
                GoalRing(goal: goal, size: 112, line: 10, marksWaiting: false)
                    .overlay(alignment: .bottomTrailing) {
                        if answered == true {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(FormGreen.approve, in: Circle())
                                .overlay(Circle().strokeBorder(EColor.surface, lineWidth: 3))
                                .offset(x: 4, y: 4)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 30)
                Text(goal.title)
                    .font(Typography.font(23, weight: .heavy))
                    .foregroundStyle(Neutral.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 14)
                // Just the prize: the ring already shows how many are left (2026-11-09).
                // The prize is optional (2026-11-15): none, no line, or just "Reached.".
                Text(goal.prize.isEmpty ? "Reached." : goal.reached ? "Reached. Your turn: \(goal.prize)" : "Prize: \(goal.prize)")
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(goal.reached ? HomeStyle.green : Neutral.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 5)
                    .opacity(goal.prize.isEmpty && !goal.reached ? 0 : 1)
                    .frame(height: goal.prize.isEmpty && !goal.reached ? 0 : nil)
                if let waiting {
                    checkInChip(goal, waiting)
                        .padding(.top, 12)
                } else if let line = todayLine(goal) {
                    Text(line.0)
                        .font(Typography.font(14, weight: .semibold))
                        .foregroundStyle(line.1)
                        .padding(.top, 8)
                }
                Spacer(minLength: 16)
                if let waiting {
                    answerButtons(goal, waiting)
                } else {
                    VStack(spacing: 10) {
                        if goal.reached {
                            wideButton("We did it", fill: Neutral.navy) {
                                countedTick += 1
                                store.finish(goal)
                            }
                        }
                        goalButtons
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .overlay(alignment: .topTrailing) {
                if waiting != nil {
                    Button { editing = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Neutral.ink)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit habit")
                    .padding(.top, 12)
                    .padding(.trailing, 10)
                }
            }
            .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
            .sensoryFeedback(.success, trigger: countedTick)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: redoTick)
            // Reached, it's a milestone now: its moment plays over this.
            .onChange(of: goal.finishedAt) { _, at in if at != nil { dismiss() } }
            // Saved, this closes too: back to Home.
            .sheet(isPresented: $editing, onDismiss: { if saved { dismiss() } }) {
                if let child = FamilyStore.children.first(where: { $0.id == goal.childId }) {
                    NewGoalSheet(child: child, editing: goal, onSaved: { saved = true })
                        .presentationDragIndicator(.visible)
                }
            }
        } else {
            // Deleted from its edit form.
            Color.clear.onAppear { dismiss() }
        }
    }

    // Where today stands. Only today's: earlier days aren't shown.
    private func todayLine(_ goal: Goal) -> (String, Color)? {
        guard let last = goal.entries.filter({ Calendar.current.isDateInToday($0.at) }).max(by: { $0.at < $1.at }) else { return nil }
        return (CheckInLook.word(last.status), CheckInLook.color(last.status))
    }

    // Who checked in and when: the child's own avatar, as at the top of Home,
    // and the time.
    private func checkInChip(_ goal: Goal, _ entry: GoalCheckIn) -> some View {
        let color = FamilyStore.children.first { $0.id == goal.childId }?.color ?? Neutral.secondary
        return HStack(spacing: 8) {
            Text(String(childName.prefix(2)).uppercased())
                .font(Typography.font(10.5, weight: .heavy))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.14), in: Circle())
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(Typography.font(14, weight: .medium))
                .foregroundStyle(Neutral.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 5)
        .padding(.trailing, 13)
        .frame(height: 36)
        .background(Neutral.tile, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(childName) checked in at \(entry.at.formatted(date: .omitted, time: .shortened))")
    }

    /// Approve (Redo was removed, 2026-11-08): the ring eases from orange to green (with a
    /// tick popping in) or back, the card holds a moment so it's seen, then
    /// closes. A check-in that reaches the habit closes it at once, for its
    /// completed moment.
    private func answer(_ goal: Goal, _ entry: GoalCheckIn, approved: Bool) {
        guard answered == nil else { return }
        heldEntry = entry
        if approved { countedTick += 1 } else { redoTick += 1 }
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { answered = approved }
        withAnimation(.easeInOut(duration: 0.55)) {
            store.review(goal, entry: entry.id, approved: approved)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (approved ? 1.0 : 0.6)) { dismiss() }
    }

    private func answerButtons(_ goal: Goal, _ entry: GoalCheckIn) -> some View {
        HStack(spacing: 10) {
            Button {
                answer(goal, entry, approved: true)
            } label: {
                HStack(spacing: 6) {
                    ApproveCheck(fontSize: 16)
                    Text(answered == true ? "Approved" : "Approve")
                        .contentTransition(.opacity)
                }
                .font(Typography.font(16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(FormGreen.approve, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .disabled(answered != nil)
    }

    // Create task's button.
    private var goalButtons: some View {
        Button { editing = true } label: {
            Text("Edit habit")
                .font(Typography.font(15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: FormGreen.accent.opacity(0.3), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func wideButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - A new goal

/// A new goal, on white: type any goal (checked against the child's age as
/// it's typed), or take one of the top three for their age and Shuffle for
/// three more. Then how many, the prize, and whether a check-in takes a photo.
/// Given a goal to edit, it opens on those details, filled in, and saves over it.
struct NewGoalSheet: View {
    @ObservedObject var child: Child
    var editing: Goal? = nil
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private enum Step { case pick, build }
    @State private var step: Step = .pick
    @State private var typed = ""
    @State private var category: GoalCategory = Self.firstCategory

    /// Household first (2026-11-16; Hygiene before); the Demo's
    /// `-EvlinGoalKind n` opens on another kind.
    private static var firstCategory: GoalCategory {
        #if EVLIN_DEMO
        let n = UserDefaults.standard.integer(forKey: "EvlinGoalKind")
        if GoalCategory.allCases.indices.contains(n) { return GoalCategory.allCases[n] }
        #endif
        return .household
    }
    @FocusState private var typing: Bool
    @FocusState private var prizeFocused: Bool
    /// The keyboard is up (a prize or the number being typed).
    @State private var keyboardUp = false
    /// One random draw of suggested prizes per opening (`GoalIdea.rewards`).
    @State private var prizeSeed = UInt64.random(in: 1...UInt64.max)

    @State private var title = ""
    @State private var target = 14
    /// Goals made here count days, one a day: nothing else to choose.
    @State private var unit = "days"
    @State private var prize = ""
    @State private var ownPrize = ""
    @State private var colorIndex = 0
    @State private var fromTyped = false
    /// The idea behind a renamable habit: its picture stays as the name changes.
    @State private var picture: String?
    /// The picture the parent picked by hand from the ring (2026-11-17):
    /// it stays as the name changes. Until then a typed habit's ring shows
    /// the drawing its words suggest (`HabitArt.suggest`), else the leaf.
    @State private var art: String?
    @State private var artByHand = false
    @State private var choosingPicture = false
    @State private var needsPhoto = false
    @State private var startedTick = 0
    @State private var askDelete = false
    /// The Habits tour's second step: the prizes lit (`HabitsTour`).
    @AppStorage(HabitsTour.prizeTipKey) private var prizeTipDone = false
    @State private var prizeFrame: CGRect?
    @State private var prizeTip = false
    /// The prize, folded away like a task's More options: it's optional
    /// (2026-11-15, the user's call; it was required before). Open when
    /// there's one to see or to pick again.
    @State private var prizeOpen = false

    /// `again`: a habit just reached, kept going as a new one with the same
    /// name, picture and length, and a different prize to pick.
    init(child: Child, editing: Goal? = nil, again: Goal? = nil, onSaved: @escaping () -> Void = {}) {
        self.child = child
        self.editing = editing
        self.onSaved = onSaved
        if let again {
            _step = State(initialValue: .build)
            _title = State(initialValue: again.title)
            _typed = State(initialValue: again.title)
            _target = State(initialValue: again.target)
            _unit = State(initialValue: again.unit)
            _colorIndex = State(initialValue: again.colorIndex)
            _picture = State(initialValue: again.picture)
            _art = State(initialValue: again.picture)
            _artByHand = State(initialValue: again.picture != nil)
            _prizeOpen = State(initialValue: true)
            return
        }
        guard let goal = editing else { return }
        _step = State(initialValue: .build)
        _title = State(initialValue: goal.title)
        _target = State(initialValue: goal.target)
        _unit = State(initialValue: goal.unit)
        // The prize is already chosen: just that, to change by typing.
        _ownPrize = State(initialValue: goal.prize)
        _prizeOpen = State(initialValue: !goal.prize.isEmpty)
        _colorIndex = State(initialValue: goal.colorIndex)
        _needsPhoto = State(initialValue: goal.needsPhoto)
        // The name is just there to tap and change.
        _typed = State(initialValue: goal.title)
        _fromTyped = State(initialValue: true)
        _picture = State(initialValue: goal.picture)
        _art = State(initialValue: goal.picture)
        _artByHand = State(initialValue: goal.picture != nil)
    }

    private static let days = 3...100
    private static let prizes = ["Movie night", "Trip to the zoo", "Pancake breakfast", "A new book", "Pick what's for dinner"]

    private var check: GoalAgeCheck { GoalAgeCheck.check(typed, age: child.age) }
    private var chosenPrize: String {
        let own = ownPrize.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? prize : own
    }

    var body: some View {
        ZStack {
            Rectangle().fill(EColor.surface).ignoresSafeArea()
            switch step {
            case .pick: pick.transition(.move(edge: .leading).combined(with: .opacity))
            case .build: build.transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if prizeTip, step == .build, let prizeFrame {
                // Over the prizes, so its longer words and Got it sit clear
                // of Add habit (2026-11-14, the user's call).
                TourSpotlight(target: prizeFrame, pad: 10, above: true) {
                    TourCard(title: "Pick a real prize",
                             words: "Children thrive on positive reinforcement and clear encouragement. Having a real prize gives Esen something exciting to work toward every day, providing a clear and motivating goal to keep in sight.") {
                        TourButton(title: "Got it", primary: true) {
                            prizeTipDone = true
                            withAnimation(.easeOut(duration: 0.3)) { prizeTip = false }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // Once the idea's set-up has slid in, the first time on this phone.
        .task(id: step) {
            guard step == .build, editing == nil, !prizeTipDone else { return }
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, step == .build else { return }
            // The tip lights the prizes themselves: the fold opens first.
            if !prizeOpen {
                withAnimation(.easeInOut(duration: 0.16)) { prizeOpen = true }
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, step == .build else { return }
            }
            withAnimation(.easeOut(duration: 0.35)) { prizeTip = true }
        }
        .onAppear {
            // Demo screenshots: the first idea's set-up.
            if ["goalbuild", "goalprize"].contains(DemoMode.parentOpen ?? ""), step == .pick, let idea = GoalIdea.picks(age: child.age).first { take(idea) }

            if ["goalown", "goalpictures"].contains(DemoMode.parentOpen ?? ""), step == .pick {
                writeOwn()
                // `-EvlinHabitTyped "Swim club"`: as if typed; `goalpictures`
                // then opens the picture picker.
                #if EVLIN_DEMO
                if let t = UserDefaults.standard.string(forKey: "EvlinHabitTyped") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { typed = t; typing = false }
                }
                #endif
                if DemoMode.parentOpen == "goalpictures" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { choosingPicture = true }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: category)
        .sensoryFeedback(.success, trigger: startedTick)
        .confirmationDialog("Delete \(title)?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let editing else { return }
                dismiss()
                // Once this sheet has gone, so the one under it closes after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { GoalStore.shared.remove(editing) }
            }
        } message: {
            Text("\(child.name)'s count goes with it.")
        }
    }

    // MARK: Pick

    // The kinds of goal as round icons across the top; under them the
    // parent types their own, or takes one of that kind's ideas (the ones
    // that suit the child's age).
    private var pick: some View {
        let ideas = GoalIdea.picks(age: child.age, in: category)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    SheetCloseButton { dismiss() }
                }
                .padding(.top, 14)
                Text("A habit for \(child.name)")
                    .font(Typography.font(28, weight: .heavy))
                    .foregroundStyle(Neutral.ink)

                categoryRow
                    .padding(.top, 22)

                // The kind's ideas as empty rings, one segment for each time
                // it counts. How many and the prize come next.
                VStack(alignment: .leading, spacing: 14) {
                    Text(category.rawValue.uppercased())
                        .font(Typography.font(12.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Neutral.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 22) {
                        ForEach(ideas) { idea in
                            Button { take(idea) } label: {
                                VStack(spacing: 8) {
                                    GoalRing(goal: Goal(id: "", childId: "", title: idea.title, target: idea.target, unit: idea.unit, prize: idea.prize),
                                             size: 88, line: 7)
                                    Text(idea.title)
                                        .font(Typography.font(13.5, weight: .semibold))
                                        .foregroundStyle(Neutral.ink)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(CardPressStyle())
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .id(category)
                .transition(.opacity)
                .padding(.top, 22)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // The six kinds as round icons, evenly across, then a + to type their
    // own: the picked one filled navy. No labels, as in Apple's own pickers.
    private var categoryRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(GoalCategory.allCases) { c in
                PickKindButton(symbol: c.symbol, name: c.rawValue, on: c == category, art: c.art) { category = c }
            }
            PickKindButton(symbol: "plus", name: "Own", on: false) { writeOwn() }
        }
    }

    private func take(_ idea: GoalIdea) {
        // No prize picked for them: it's optional, folded under Prize
        // (2026-11-15; the idea's own default was picked before).
        title = idea.title; target = idea.target; prize = ""
        ownPrize = ""
        // A renamable idea opens with its name as a field to change.
        fromTyped = idea.renamable
        typed = idea.renamable ? idea.title : ""
        picture = idea.renamable ? idea.title : nil
        art = nil; artByHand = false
        unit = "days"; colorIndex = idea.colorIndex
        needsPhoto = false
        typing = false
        withAnimation(.snappy(duration: 0.3)) { step = .build }
    }

    // The +: straight to the details, with the cursor in the goal's name.
    private func writeOwn() {
        typed = ""
        picture = nil
        art = nil; artByHand = false
        title = ""
        target = 14
        unit = "days"
        prize = ""; ownPrize = ""
        needsPhoto = false
        colorIndex = GoalStore.shared.goals(for: child.id).count
        fromTyped = true
        // A typed habit's prizes show right away, open (2026-11-17, the
        // user's call).
        prizeOpen = true
        withAnimation(.snappy(duration: 0.3)) { step = .build }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { typing = true }
    }

    /// The picture in the ring and saved with the habit: the one picked by
    /// hand, else the idea's, else for a typed habit the drawing its words
    /// suggest; nil leaves it to the title (an idea's own, or the leaf).
    private var shownPicture: String? {
        if artByHand { return art }
        if let picture { return picture }
        // A typed habit no drawing fits is the leaf (2026-11-17, the
        // user's call), not a symbol from its words.
        return fromTyped ? (HabitArt.suggest(for: typed) ?? Goal.leafPicture) : nil
    }

    // The goal's name, as typed or as chosen.
    private var goalTitle: String {
        guard fromTyped, !nameUnchanged else { return title }
        return GoalAgeCheck.draft(from: typed).title
    }

    // Editing with the name as it was: it stays exactly so, and isn't checked again.
    private var nameUnchanged: Bool { editing != nil && typed == editing?.title }

    // A name under the ring to type in. Says something only when what's typed
    // doesn't suit the child's age.
    private var nameField: some View {
        let c = check
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Type a habit", text: $typed, axis: .vertical)
                .font(Typography.font(20, weight: .heavy))
                .foregroundStyle(Neutral.ink)
                .focused($typing)
                .submitLabel(.done)
                .lineLimit(1...2)
                // Return ends the typing (a two-line field would take it as a
                // new line), so Add habit is right there (2026-11-15).
                .onChange(of: typed) { _, new in
                    guard new.contains("\n") else { return }
                    typed = new.replacingOccurrences(of: "\n", with: "")
                    typing = false
                }
            if c.verdict == .notYet && !nameUnchanged {
                HStack(spacing: 6) {
                    Text(c.message).foregroundStyle(HomeStyle.waiting)
                    if let instead = c.instead {
                        Button { typed = instead } label: {
                            Text("Try “\(instead)”").foregroundStyle(Neutral.ink).underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(Typography.font(13.5, weight: .semibold))
            }
        }
        .animation(.easeOut(duration: 0.2), value: c.verdict)
    }

    // MARK: Build

    private var build: some View {
        // A renamed idea isn't checked against the child's age: it's still the idea.
        let named = (!fromTyped || nameUnchanged || picture != nil || check.verdict == .ok)
            && !(fromTyped && typed.trimmingCharacters(in: .whitespaces).isEmpty)
        // The prize is optional (2026-11-15): a name is all it takes.
        let ready = named
        let done = min(editing?.done ?? 0, target)
        return VStack(spacing: 0) {
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if editing == nil {
                            Button { withAnimation(.snappy(duration: 0.3)) { step = .pick } } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Neutral.ink)
                                    .frame(width: 44, height: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")
                        }
                        // Editing: the trash can across from the close, as on a task.
                        if editing != nil {
                            SheetDeleteButton(label: "Delete habit") { askDelete = true }
                        }
                        Spacer()
                        SheetCloseButton { dismiss() }
                    }
                    .padding(.top, 14)

                    HStack(spacing: 14) {
                        // A tap shows every picture to pick from (2026-11-17).
                        Button { typing = false; choosingPicture = true } label: {
                            GoalRing(goal: { var g = Goal(id: "", childId: "", title: goalTitle, target: target, unit: unit, prize: chosenPrize, done: done, colorIndex: colorIndex); g.picture = shownPicture; return g }(),
                                     size: 64, line: 7)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Neutral.ink)
                                        .frame(width: 22, height: 22)
                                        .background(EColor.chip, in: Circle())
                                        .overlay(Circle().stroke(EColor.chipEdge, lineWidth: 1))
                                        .offset(x: 3, y: 3)
                                }
                                .animation(.snappy(duration: 0.25), value: shownPicture)
                        }
                        .buttonStyle(CardPressStyle())
                        .accessibilityLabel("Change picture")
                        .sheet(isPresented: $choosingPicture) {
                            HabitPicturePicker(current: shownPicture ?? (HabitArt.has(goalTitle) ? goalTitle : nil)) { p in
                                art = p; artByHand = true
                            }
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .presentationBackground(EColor.surface)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if fromTyped {
                                nameField
                            } else {
                                Text(title)
                                    .font(Typography.font(20, weight: .heavy))
                                    .foregroundStyle(Neutral.ink)
                                    .lineLimit(2)
                            }
                            Text("\(done) of \(target) \(Goal.words(unit))" + (chosenPrize.isEmpty ? "" : " · \(chosenPrize)"))
                                .font(Typography.font(14, weight: .regular))
                                .foregroundStyle(Neutral.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)

                    label(unit == "times" ? "How many times?" : "How many days?")
                    HStack(spacing: 22) {
                        roundButton("minus") { target = max(Self.days.lowerBound, target - 1) }
                        DayWheel(value: $target, range: Self.days)
                        roundButton("plus") { target = min(Self.days.upperBound, target + 1) }
                    }
                    .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        ForEach([7, 14, 30], id: \.self) { n in
                            pill("\(n)", on: target == n) { target = n }
                        }
                    }
                    .padding(.top, 14)

                    // An idea's own prizes, then treats; a habit the parent
                    // typed (the +) gets the treats, shown open from the
                    // start (2026-11-17, the user's call; just the field
                    // from 2026-11-05).
                    // All of it folded under a Prize row, as a task's More
                    // options: optional (2026-11-15, the user's call).
                    let ownHabit = fromTyped && picture == nil
                    VStack(alignment: .leading, spacing: 0) {
                        prizeRow
                        if prizeOpen && editing == nil {
                            // The habit's own rewards (3 to 5), else the general few.
                            PrizeChips(items: ownHabit ? GoalIdea.treats(seed: prizeSeed)
                                                : (GoalIdea.rewards(for: picture ?? title, seed: prizeSeed) ?? Self.prizes),
                                       selected: ownPrize.isEmpty ? prize : "") { p in
                                // A tap on the picked one unpicks it: no prize.
                                prize = (prize == p && ownPrize.isEmpty) ? "" : p; ownPrize = ""
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The tour lights the Prize row and its chips.
                    .onGeometryChange(for: CGRect.self) { g in g.frame(in: .global) } action: { prizeFrame = $0 }
                    .padding(.top, 20)
                    if prizeOpen {
                    TextField(editing == nil ? "Or type your own prize" : "Type a prize", text: $ownPrize)
                        .font(Typography.font(15, weight: .regular))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 10)
                        .focused($prizeFocused)
                        .submitLabel(.done)
                        .onSubmit { prizeFocused = false }
                    }
                    // What the field scrolls to while typing: a set gap
                    // under it, so it sits clear of the keyboard (2026-11-08).
                    // 64 while typing: the keyboard's suggestion bar covers
                    // the bottom of the sheet's room, and 20 left the field
                    // flush against it (2026-11-14).
                    Color.clear.frame(height: keyboardUp ? 64 : 20).id("prizeField")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
            // Typing a prize: the field rises to sit just above the keyboard.
            .onChange(of: prizeFocused) { _, on in
                guard on else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo("prizeField", anchor: .bottom) }
                }
            }
            }

            Button {
                guard ready else { return }
                startedTick += 1
                if let editing {
                    GoalStore.shared.update(editing, title: goalTitle, target: target, prize: chosenPrize, needsPhoto: needsPhoto,
                                            picture: shownPicture)
                    onSaved()
                } else {
                    let added = GoalStore.shared.add(childId: child.id, title: goalTitle, target: target, unit: unit, prize: chosenPrize,
                                                     needsPhoto: needsPhoto, picture: shownPicture)
                    // The first habit: its tour shows on its ring on Home.
                    HabitTour.habitAdded(added)
                }
                dismiss()
            } label: {
                Text(editing == nil ? "Add habit" : "Save")
                    .font(Typography.font(17, weight: .bold))
                    .foregroundStyle(ready ? .white : Neutral.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(ready ? FormGreen.accent : EColor.outlineVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: ready ? FormGreen.accent.opacity(0.3) : .clear, radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // Out of the way while typing a prize or the number (it sat over
            // the prizes, its glow over the field, 2026-11-08); back when the
            // keyboard goes. Typing the habit's name it stays, over the
            // keyboard: hidden then, a typed habit had no button to add it
            // (2026-11-15).
            .opacity(keyboardUp && !typing ? 0 : 1)
            .frame(height: keyboardUp && !typing ? 0 : nil)
            .clipped()
        }
        // Demo screenshots: typing a prize, the keyboard up.
        .task {
            guard DemoMode.parentOpen == "goalprize" else { return }
            prizeOpen = true
            try? await Task.sleep(for: .seconds(1.5))
            prizeFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = false }
        }
    }

    /// The Prize row: More options' look, the chosen prize at the right
    /// (or "None"), the chevron turning as it opens.
    private var prizeRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { prizeOpen.toggle() }
            if !prizeOpen { prizeFocused = false }
        } label: {
            HStack(spacing: 8) {
                Text("Prize").font(FormRow.title).foregroundStyle(FormGreen.title)
                Spacer()
                // No "None" for a typed habit (2026-11-17, the user's call):
                // its prizes are already open under the row.
                Text(chosenPrize.isEmpty ? (fromTyped && picture == nil && editing == nil ? "" : "None") : chosenPrize)
                    .font(FormRow.value)
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .lineLimit(1)
                FormRow.chevron(open: prizeOpen)
            }
            .frame(minHeight: FormRow.height)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { FormRow.line }
        }
        .buttonStyle(.plain)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.font(17, weight: .heavy))
            .foregroundStyle(FormGreen.title)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Neutral.ink)
                .frame(width: 48, height: 48)
                .background(Neutral.tile, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "More" : "Fewer")
    }

    /// A picked day or prize: setup's soft green pick (2026-11-14, the
    /// user's call: warm sand, #E6DFD1 / #3A3631, read brown on the charcoal).
    /// Crisp, not minty: a warm sage wash that sits on the cream, edged in
    /// the Create / Approve green, deep-green words (2026-11-14: setup's
    /// mint #DCF1E1 with a pale edge looked washed out).
    static let picked = Color(light: "E6F0DE", dark: "22382A")
    static let pickedEdge = Color(light: "2FA84F", dark: "3A9257")
    static let pickedInk = Color(light: "1B5E30", dark: "E2F0DA")
    /// Not picked: a soft tone a step under the page with a firm warm edge,
    /// so each chip reads on its own (2026-11-14, the user's call: the
    /// page's own colour with a faint #DCD7CC edge blended into the page).
    static let unpicked = EColor.chip
    static let unpickedEdge = EColor.chipEdge

    private func pill(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Typography.font(15, weight: .semibold))
                // Picked: soft green, deep-green words (solid green and black
                // were tried, 2026-11-05; warm sand until 2026-11-14).
                .foregroundStyle(on ? Self.pickedInk : Neutral.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(on ? Self.picked : Self.unpicked, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Self.pickedEdge : Self.unpickedEdge, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

}

/// The goal's number of days, big, and only that number on screen. Drag it up
/// or down to scroll through the numbers; tap it to type one (a wheel showing the
/// numbers around it was tried and rejected).
private struct DayWheel: View {
    @Binding var value: Int
    var range: ClosedRange<Int>

    @State private var dragStart: Int?
    @State private var typing = DemoMode.parentOpen == "goaltype"
    @State private var draft = ""
    @FocusState private var focused: Bool
    private let step: CGFloat = 8

    private var numberFont: Font { Typography.font(48, weight: .heavy) }

    var body: some View {
        Group {
            if typing {
                TextField("", text: $draft)
                    .keyboardType(.numberPad)
                    .font(numberFont)
                    .foregroundStyle(FormGreen.title)
                    .tint(FormGreen.accent)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .frame(width: 96)
                    .focused($focused)
                    .onAppear {
                        draft = "\(value)"
                        // After the tap that opened it, which closes any keyboard.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { finishTyping() } }
                    // − + or a pill while typing: that number wins.
                    .onChange(of: value) { _, new in if Int(draft) != new { draft = "\(new)" } }
                    .onChange(of: draft) { _, new in
                        draft = String(new.filter(\.isNumber).prefix(3))
                        // Counts as it's typed, so Save right after keeps it.
                        if let typed = Int(draft), range.contains(typed) { value = typed }
                    }
                    // No Done bar over the number pad (2026-11-08: it floated
                    // oddly); a tap anywhere else ends the typing.
            } else {
                Text("\(value)")
                    .font(numberFont)
                    .foregroundStyle(FormGreen.title)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .frame(minWidth: 96)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UISelectionFeedbackGenerator().selectionChanged()
                        typing = true
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { g in
                                let start = dragStart ?? value
                                dragStart = start
                                let next = min(range.upperBound, max(range.lowerBound, start - Int((g.translation.height / step).rounded())))
                                if next != value {
                                    value = next
                                    UISelectionFeedbackGenerator().selectionChanged()
                                }
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
        }
        .animation(.snappy(duration: 0.2), value: value)
        .accessibilityElement()
        .accessibilityLabel("Days")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    // What's typed, kept within the range. Nothing typed leaves it as it was.
    private func finishTyping() {
        if let typed = Int(draft) { value = min(range.upperBound, max(range.lowerBound, typed)) }
        typing = false
    }
}

/// Prize chips that wrap onto as many lines as they need.
private struct PrizeChips: View {
    var items: [String]
    var selected: String
    var onPick: (String) -> Void

    var body: some View {
        PrizeWrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = item == selected
                Button { onPick(item) } label: {
                    Text(item)
                        .font(Typography.font(14, weight: .semibold))
                        // Picked like the day pills: soft green.
                        .foregroundStyle(on ? NewGoalSheet.pickedInk : Neutral.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(on ? NewGoalSheet.picked : NewGoalSheet.unpicked, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? NewGoalSheet.pickedEdge : NewGoalSheet.unpickedEdge, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PrizeWrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
