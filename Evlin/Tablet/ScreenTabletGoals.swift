import SwiftUI

// The kid's Goals tab, apart from Tasks: goals never lock or open the iPad.
// Today's goals are rings (2026-11-16; a chore list with the sent ones as rings
// under it before). Tap one to go inside it and hold Send; it goes to the
// parent, the days left tick down, and the ring waits for approval. A goal that takes a photo opens a page like a task's
// instead, with the same hold. A goal reached today shows its prize, a gift in a
// circle, until the day ends; from the next day it's in Completed: a row at
// the foot of the tab, tapped to open them all (2026-11-15, the user's call:
// tucked away; shown on the tab itself earlier the same day), each a full
// green ring with its picture, its name and the days it took, as the
// parent's Profile shows it, newest first.
//
// Goals live on the device for now (GoalStore): there's no server for them
// yet, so a check-in here doesn't reach the parent's phone.
struct ScreenTabletGoals: View {
    @Environment(SessionManager.self) private var session
    @ObservedObject private var store = GoalStore.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var opened: Goal?
    @State private var showsCompleted = false
    @State private var sentTick = 0

    private var childId: String { session.activeChildId ?? FamilyStore.children.first?.id ?? "" }

    var body: some View {
        // A reached goal has nothing left to send in.
        let goals = store.goals(for: childId).filter { !$0.reached }
        let toDo = goals.filter { !$0.checkedInToday }
        let prizes = store.prizesToday(for: childId)
        // Reached before today (today's is the prize above).
        let completed = store.milestones(for: childId)
            .filter { $0.finishedAt.map(Calendar.current.isDateInToday) != true }
        let kid = KidAdaptive(hSizeClass)
        ScrollView {
            VStack(spacing: 0) {
                if goals.isEmpty && prizes.isEmpty {
                    GoalEmptyRings(kid: kid)
                } else {
                    // Every habit is a ring, in its own order (2026-11-16, the
                    // user's call: rows for the ones still to do before); a tap
                    // on one not yet sent opens Hold to send.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: kid.of(150, 172)), spacing: 16, alignment: .top)], spacing: kid.of(28, 36)) {
                        ForEach(prizes) { goal in
                            GoalPrizeCircle(goal: goal, kid: kid)
                        }
                        ForEach(goals) { goal in
                            GoalTodayRing(goal: goal, kid: kid) { opened = goal }
                                .modifier(KidTourFirst(on: goal.id == (toDo.first ?? goals.first)?.id, spot: .ring))
                        }
                    }
                }
                if !completed.isEmpty {
                    GoalsCompletedRow(goals: completed, kid: kid) { showsCompleted = true }
                        .padding(.top, kid.of(36, 48))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, kid.of(20, 40))
            .padding(.top, kid.of(20, 36))
            .padding(.bottom, 40)
        }
        .background(EPaperBackground())
        .sensoryFeedback(.success, trigger: sentTick)
        .fullScreenCover(isPresented: $showsCompleted) {
            GoalsCompletedPage(goals: store.milestones(for: childId)
                .filter { $0.finishedAt.map(Calendar.current.isDateInToday) != true }) {
                showsCompleted = false
            }
        }
        .fullScreenCover(item: $opened) { goal in
            if goal.needsPhoto {
                GoalPhotoPage(goal: goal) { photo in
                    opened = nil
                    send(goal, photo: GoalProof.save(photo: photo), after: 0.45)
                } onClose: { opened = nil }
            } else {
                GoalSendPage(goal: goal) {
                    opened = nil
                    send(goal, after: 0.45)
                } onClose: { opened = nil }
            }
        }
        .task {
            if DemoMode.kidOpenCompleted {
                showsCompleted = true
            } else if DemoMode.kidGoalPhoto != nil {
                opened = goals.first { $0.needsPhoto && !$0.checkedInToday }
            } else if DemoMode.kidGoalSend, let goal = toDo.first(where: { !$0.needsPhoto }) {
                try? await Task.sleep(for: .seconds(1.5))
                send(goal)
            }
        }
    }

    private func send(_ goal: Goal, photo: String? = nil, after delay: Double = 0) {
        sentTick += 1
        Task {
            // After a page closing over the rings, so the number is seen ticking down.
            try? await Task.sleep(for: .seconds(delay))
            withAnimation(.easeOut(duration: 0.3)) { store.checkIn(goal, photo: photo) }
        }
    }
}

/// How long Send takes to hold.
private enum GoalHold {
    static let seconds = 2.0
}

private extension View {
    /// Press and hold: `glow` climbs from 0 to 1, and all the way up calls
    /// `onHeld`. Letting go early takes it back.
    func holdToSend(glow: Binding<Double>, onHeld: @escaping () -> Void) -> some View {
        onLongPressGesture(minimumDuration: GoalHold.seconds, maximumDistance: 30) {
            onHeld()
        } onPressingChanged: { down in
            withAnimation(down ? .linear(duration: GoalHold.seconds) : .easeOut(duration: 0.2)) {
                glow.wrappedValue = down ? 1 : 0
            }
        }
    }
}

/// Inside a goal with no photo: its ring with the number left, and Send to hold.
private struct GoalSendPage: View {
    var goal: Goal
    var onSend: () -> Void
    var onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        let kid = KidAdaptive(hSizeClass)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(KidTheme.greenDeep)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            Text(goal.title)
                .font(Typography.font(28, weight: .heavy))
                .foregroundStyle(KidTheme.ink)
                .padding(.top, 8)

            Spacer(minLength: 20)
            GoalRing(goal: goal, size: 200, line: 200 * goalLineShare, countsWaiting: true)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 20)

            GoalHoldButton(onHeld: onSend)
        }
        .padding(.horizontal, kid.of(20, 32))
        .padding(.bottom, 24)
        .kidContentColumn(kid.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EPaperBackground())
    }
}

/// One habit today: its ring with the number left and its name. Not yet sent
/// in, a tap goes inside it to Hold to send; sent, it waits for approval.
private struct GoalTodayRing: View {
    var goal: Goal
    var kid: KidAdaptive
    var onOpen: () -> Void

    private var sent: Bool { goal.checkedInToday }
    // A grown-up asked for another go: it opens again today.
    private var redo: Bool {
        !sent && goal.entries.contains { Calendar.current.isDateInToday($0.at) && $0.status == .notApproved }
    }

    var body: some View {
        let size: CGFloat = kid.of(112, 136)
        Button(action: onOpen) {
            VStack(spacing: 10) {
                GoalRing(goal: goal, size: size, line: size * goalLineShare, countsWaiting: true, waitsOrange: true)
                VStack(spacing: 2) {
                    GoalRingStyle.name(goal.title)
                    if sent && !goal.waitingToday.isEmpty {
                        // In the ring's orange, as the parent's "Tap to approve".
                        note("Waiting for approval", GoalRingStyle.waitingBadge)
                    } else if redo {
                        note("Try again", KidTheme.inkSoft)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(haptic: true))
        .disabled(sent)
        .accessibilityElement(children: .combine)
        .accessibilityHint(sent ? "" : "Opens Hold to send")
    }

    private func note(_ words: String, _ color: Color) -> some View {
        Text(words)
            .font(Typography.font(13, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

/// Completed habits, tucked away: one row at the foot of the tab, the
/// newest one's ring, "Completed" and how many, opening them all.
private struct GoalsCompletedRow: View {
    var goals: [Goal]
    var kid: KidAdaptive
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 16) {
                let size: CGFloat = kid.of(46, 52)
                ZStack {
                    Circle().stroke(GoalRingStyle.green, lineWidth: kid.of(5, 5.5))
                        .padding(kid.of(2.5, 2.75))
                    if let newest = goals.first {
                        GoalIcon(goal: newest, size: size * 0.5)
                    }
                }
                .frame(width: size, height: size)
                Text("Completed")
                    .font(Typography.font(kid.of(17, 19), weight: .semibold))
                    .foregroundStyle(KidTheme.ink)
                Spacer(minLength: 8)
                Text("\(goals.count)")
                    .font(Typography.font(kid.of(20, 22), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(GoalRingStyle.label)
                Image(systemName: "chevron.right")
                    .font(.system(size: kid.of(16, 18), weight: .semibold))
                    .foregroundStyle(KidTheme.inkSoft)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, kid.of(14, 18))
            .padding(.vertical, kid.of(12, 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KidTheme.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(KidTheme.line))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Completed, \(goals.count)")
    }
}

/// Every habit reached before today, newest first: full green rings, each
/// with its picture, its name and the days it took.
private struct GoalsCompletedPage: View {
    var goals: [Goal]
    var onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        let kid = KidAdaptive(hSizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.left")
                        .font(Typography.font(16, weight: .semibold))
                        .foregroundStyle(KidTheme.greenDeep)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                Text("Completed")
                    .font(Typography.font(28, weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                    .padding(.top, 8)
                    .padding(.bottom, kid.of(24, 32))
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: kid.of(150, 172)), spacing: 16, alignment: .top)], spacing: kid.of(28, 36)) {
                    ForEach(goals) { goal in
                        CompletedMilestoneRing(goal: goal, size: kid.of(112, 136), showsDate: false)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, kid.of(20, 32))
            .padding(.bottom, 40)
            .kidContentColumn(kid.contentMaxWidth)
        }
        .background(EPaperBackground())
    }
}

/// The line's share of a big ring on this tab.
private let goalLineShare: CGFloat = 0.09

/// No goals: their empty places, and nothing to read.
private struct GoalEmptyRings: View {
    var kid: KidAdaptive

    var body: some View {
        let size: CGFloat = kid.of(112, 136)
        let line = size * goalLineShare
        LazyVGrid(columns: [GridItem(.adaptive(minimum: kid.of(150, 172)), spacing: 16)], spacing: kid.of(28, 36)) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .stroke(GoalRingStyle.track, lineWidth: line)
                    .padding(line / 2)
                    .frame(width: size, height: size)
                    .modifier(KidTourFirst(on: i == 0, spot: .ring))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No habits yet")
    }
}

/// A goal reached today: a gift in a circle, in place of a full ring, and the
/// prize under it, until the day ends.
private struct GoalPrizeCircle: View {
    var goal: Goal
    var kid: KidAdaptive

    var body: some View {
        let look = MilestoneLook.of(goal)
        let size: CGFloat = kid.of(112, 136)
        VStack(spacing: 10) {
            Image(systemName: "gift.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(look.accent)
                .frame(width: size, height: size)
                .background(look.card, in: Circle())
            VStack(spacing: 2) {
                GoalRingStyle.name(goal.prize.isEmpty ? goal.title : goal.prize)
                Text("Your prize")
                    .font(Typography.font(13, weight: .medium))
                    .foregroundStyle(KidTheme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A goal that takes a photo: the same steps as a task. Tap to take it, look it
/// over, then hold to send. Sent, it closes and the days left tick down.
private struct GoalPhotoPage: View {
    var goal: Goal
    var onSend: (UIImage) -> Void
    var onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var photo: UIImage? = DemoMode.kidGoalPhoto
    @State private var showCamera = false

    var body: some View {
        let kid = KidAdaptive(hSizeClass)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(KidTheme.greenDeep)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            Text(goal.title)
                .font(Typography.font(28, weight: .heavy))
                .foregroundStyle(KidTheme.ink)
                .padding(.top, 8)
                .padding(.bottom, 20)

            if let photo {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button { showCamera = true } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(KidTheme.ink.opacity(0.8), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .accessibilityLabel("Take another")
                    }
                GoalHoldButton { onSend(photo) }
                    .padding(.top, 18)
            } else {
                Button { showCamera = true } label: {
                    VStack(spacing: 16) {
                        Circle().fill(GoalRingStyle.green).frame(width: 84, height: 84)
                            .overlay(Image(systemName: "camera.fill").font(.system(size: 36, weight: .bold)).foregroundStyle(.white))
                        Text("Tap to take a photo")
                            .font(Typography.font(20, weight: .bold))
                            .foregroundStyle(KidTheme.ink)
                        Text("Show us what you did")
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(KidTheme.inkSoft)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KidTheme.cream)
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(KidTheme.line, style: StrokeStyle(lineWidth: 2.5, dash: [7])))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, kid.of(20, 32))
        .padding(.bottom, 24)
        .kidContentColumn(kid.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EPaperBackground())
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture(onCapture: { image in
                photo = image
                showCamera = false
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
    }
}

/// Hold to send, inside a goal: it glows and fills as it's held.
private struct GoalHoldButton: View {
    var onHeld: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Text("Hold to send")
            .font(KidTheme.buttonFont(19))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // The kid's button green, as setup's (2026-11-16;
                        // the rings' #34C759 before).
                        KidTheme.paperButton
                        KidTheme.greenDeep.frame(width: geo.size.width * glow)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .shadow(color: KidTheme.paperButton.opacity(0.8 * glow), radius: 22 * glow)
            .scaleEffect(1 + 0.02 * glow)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .holdToSend(glow: $glow, onHeld: onHeld)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onHeld() }
    }
}
