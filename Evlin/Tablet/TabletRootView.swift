import SwiftUI

struct TabletRootView: View {
    var onSwitchMode: () -> Void
    @State private var tab = 0
    @State private var tasks = TabletData.tasks
    // Lifted up from ScreenTabletHome so the Ring tab's tokens can open the
    // same task detail flow — both tabs share this one `tasks` array, so
    // completing/redoing a task from either place needs to land in the
    // same source of truth rather than each tab keeping its own copy.
    @State private var selectedTask: KidTask?

    // Screen-time numbers used to live only in the immutable TabletData.child
    // snapshot — lifted into @State here so it can actually mutate.
    @State private var usedMin = TabletData.child.usedMin
    @State private var limitMin = TabletData.child.limitMin
    @State private var onBreakUntil: Date?

    // "Your tasks for today" intro — shown once per app session, before the
    // kid sees their list, framing the day ahead. Purely a session flag (no
    // persistence anywhere else in this prototype either).
    @State private var showDayIntro = true
    // The finish-all-tasks celebration -> screen-time reveal, triggered the
    // moment doneCount reaches the total. Reset if a task gets un-done (a
    // parent Redo) so finishing everything again replays the payoff.
    @State private var celebrationStage: CelebrationStage?
    @State private var didCelebrateThisCompletion = false

    private var doneCount: Int { tasks.filter(\.done).count }
    private var locked: Bool { doneCount < tasks.count }
    private var minutesLeft: Int { max(0, limitMin - usedMin) }
    private var onBreak: Bool { if let until = onBreakUntil { return Date() < until } else { return false } }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if tab == 0 {
                    PlayTimeTopBar(minutesLeft: minutesLeft, minutesMax: limitMin, locked: locked, done: doneCount, total: tasks.count, onBreak: onBreak)
                }
                // No Settings tab here — its only content was the Parent
                // Controls request, so a whole bottom-nav slot represented a
                // single feature rather than an actual settings section
                // (unlike, say, Telegram's Settings, which is genuinely its
                // own place). That access point now lives behind a small
                // gear icon in this tab's own toolbar (see ScreenTabletHome)
                // instead of being mistaken for real settings.
                TabView(selection: $tab) {
                    ScreenTabletHome(tasks: $tasks, onSwitchMode: onSwitchMode, onSelectTask: { selectedTask = $0 })
                        .tabItem { Label("Task", systemImage: "checkmark.circle.fill") }
                        .tag(0)
                    ScreenTabletCalendar()
                        .tabItem { Label("Calendar", systemImage: "calendar") }
                        .tag(1)
                    ScreenTabletLibrary()
                        .tabItem { Label("Library", systemImage: "book.closed.fill") }
                        .tag(2)
                }
                .tint(KidTheme.greenDeep)
                // The native tab bar paints its own opaque system background
                // (white) regardless of what's behind it — without this it was
                // the one remaining plain-white strip on every kid screen, even
                // after the KidTheme cream/sage port.
                .toolbarBackground(KidTheme.cream, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
            .background(KidTheme.background)

            if showDayIntro {
                TaskDayIntroOverlay(childName: TabletData.child.name, taskCount: tasks.count) {
                    withAnimation(.easeOut(duration: 0.3)) { showDayIntro = false }
                }
                .transition(.opacity)
            }

            if let stage = celebrationStage {
                TaskCompletionOverlay(stage: stage, childName: TabletData.child.name, limitMin: limitMin) {
                    switch stage {
                    case .congrats:
                        withAnimation(.easeInOut(duration: 0.25)) { celebrationStage = .reveal }
                    case .reveal:
                        withAnimation(.easeOut(duration: 0.3)) { celebrationStage = nil }
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: doneCount) { _, newValue in
            if newValue == tasks.count, !tasks.isEmpty, !didCelebrateThisCompletion {
                didCelebrateThisCompletion = true
                withAnimation(.easeInOut(duration: 0.25)) { celebrationStage = .congrats }
            } else if newValue < tasks.count {
                didCelebrateThisCompletion = false
            }
        }
        .fullScreenCover(item: $selectedTask) { task in
            TaskDetailView(task: task, onComplete: { photoCount, note, hasVoiceNote in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].done = true
                    tasks[i].submittedPhotoCount = photoCount
                    tasks[i].submissionNote = note
                    tasks[i].submissionHasVoiceNote = hasVoiceNote
                    // Submitting means "a parent hasn't looked at it yet,"
                    // not "fully approved" — see KidTask.pendingApproval.
                    // Clearing redoRequested too: a resubmission after a
                    // redo ask puts the task right back into the review
                    // queue instead of staying stuck showing the old note.
                    tasks[i].pendingApproval = true
                    tasks[i].approved = false
                    tasks[i].redoRequested = false
                }
                selectedTask = nil
            }, onRequestBypass: { reason, hasVoice in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].bypassRequested = true
                    tasks[i].bypassNote = reason.isEmpty ? nil : reason
                    tasks[i].bypassHasVoiceNote = hasVoice
                }
            })
        }
    }
}

private enum CelebrationStage { case congrats, reveal }

// Full-bleed "your tasks for today" moment shown once before the list, so
// the day starts with a beat of framing rather than dropping straight into
// a checklist. Tap-to-continue (not a bare timer) so a kid who taps early
// isn't stuck waiting, matching the CTA-driven pattern the rest of kid mode
// uses rather than a silent auto-advancing splash.
private struct TaskDayIntroOverlay: View {
    var childName: String
    var taskCount: Int
    var onContinue: () -> Void

    @State private var appeared = false
    // A full-bleed splash-style overlay, not a pushed screen — without a
    // cap its icon/copy/CTA just spread across the full iPad width, most
    // visibly as an edge-to-edge "Let's go!" button that reads like a
    // stretched phone screen rather than an iPad-sized moment.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    var body: some View {
        ZStack {
            KidTheme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle().fill(KidTheme.greenTint).frame(width: kid.of(132, 168), height: kid.of(132, 168))
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: kid.of(56, 72)))
                        .foregroundStyle(KidTheme.greenDeep)
                }
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Your tasks for today")
                        .font(Typography.display(kid.of(28, 34), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(taskCount == 1
                         ? "You've got 1 thing to knock out, \(childName)."
                         : "You've got \(taskCount) things to knock out, \(childName).")
                        .font(Typography.font(kid.of(15, 17), weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

                Spacer()
                Spacer()

                Button(action: onContinue) {
                    Text("Let's go!")
                        .font(Typography.display(18, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            // Offset duplicate behind the face, not
                            // `.shadow()` — that ghosts the label text too.
                            ZStack {
                                RoundedRectangle(cornerRadius: 20).fill(KidTheme.greenDeep).offset(y: 5)
                                RoundedRectangle(cornerRadius: 20).fill(KidTheme.green)
                            }
                            // Flattened into one layer first so any future
                            // press/disabled dimming can't split the two
                            // rectangles apart into a smeared double edge.
                            .compositingGroup()
                        )
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .kidContentColumn(kid.isRegular ? 560 : nil)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
        }
        .onTapGesture { onContinue() }
    }
}

// Two-beat payoff for finishing every task: a congrats card, then (on
// "Continue") the screen-time reveal — kept as separate beats rather than
// combining them so the reward itself (the reveal) reads as its own moment,
// not a footnote line on the congrats card.
private struct TaskCompletionOverlay: View {
    var stage: CelebrationStage
    var childName: String
    var limitMin: Int
    var onContinue: () -> Void

    @State private var appeared = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private var timeLabel: String {
        let h = limitMin / 60, m = limitMin % 60
        if h > 0, m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    var body: some View {
        ZStack {
            KidTheme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle().fill(KidTheme.greenTint).frame(width: kid.of(132, 168), height: kid.of(132, 168))
                    Image(systemName: stage == .congrats ? "star.fill" : "clock.fill")
                        .font(.system(size: kid.of(56, 72)))
                        .foregroundStyle(KidTheme.greenDeep)
                }
                .scaleEffect(appeared ? 1 : 0.4)
                .rotationEffect(.degrees(appeared ? 0 : -12))

                VStack(spacing: 8) {
                    Text(stage == .congrats ? "Great job, \(childName)! 🎉" : "You unlocked \(timeLabel)!")
                        .font(Typography.display(kid.of(28, 34), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(stage == .congrats
                         ? "You finished every task today. That's the whole list!"
                         : "That's your play time for today — go have fun.")
                        .font(Typography.font(kid.of(15, 17), weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)

                Spacer()
                Spacer()

                Button(action: onContinue) {
                    Text(stage == .congrats ? "Continue" : "Let's play!")
                        .font(Typography.display(18, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            // Offset duplicate behind the face, not
                            // `.shadow()` — that ghosts the label text too.
                            ZStack {
                                RoundedRectangle(cornerRadius: 20).fill(KidTheme.greenDeep).offset(y: 5)
                                RoundedRectangle(cornerRadius: 20).fill(KidTheme.green)
                            }
                            // Flattened into one layer first so any future
                            // press/disabled dimming can't split the two
                            // rectangles apart into a smeared double edge.
                            .compositingGroup()
                        )
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .kidContentColumn(kid.isRegular ? 560 : nil)
        }
        // Re-fires the entrance beat on every stage change (congrats ->
        // reveal is a whole new ZStack instance since `stage` swaps the
        // icon/copy, but SwiftUI could preserve identity given the layout
        // is otherwise unchanged — .id forces a fresh appear each time).
        .id(stage)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) { appeared = true }
        }
    }
}

private struct PlayTimeTopBar: View {
    var minutesLeft: Int
    var minutesMax: Int
    var locked: Bool
    var done: Int
    var total: Int
    var onBreak: Bool = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private var frac: Double {
        locked ? 0 : max(0, min(1, minutesMax > 0 ? Double(minutesLeft) / Double(minutesMax) : 0))
    }
    private var accent: Color { locked ? Color(hex: "DB9A00") : KidTheme.greenDeep }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(locked ? Color(hex: "FFF4DC") : .white)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: locked ? "lock.fill" : "clock.fill").font(.system(size: 17)).foregroundStyle(accent))
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("PLAY TIME TODAY").font(Typography.font(11, weight: .bold)).tracking(0.4).foregroundStyle(KidTheme.inkSoft)
                        Spacer()
                        Text(onBreak ? "On a break" : (locked ? "Locked" : "\(minutesLeft / 60 > 0 ? "\(minutesLeft / 60)h " : "")\(minutesLeft % 60)m left"))
                            .font(Typography.display(18, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    }
                    GeometryReader { geo in
                        Capsule().fill(locked ? Color(hex: "F3EBD8") : KidTheme.greenTint).frame(height: 8)
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent).frame(width: geo.size.width * frac, height: 8)
                            }
                    }
                    .frame(height: 8)
                }
            }
            .padding(14)
            .background(KidTheme.cream)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.line))
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if locked {
                Text("\(done) of \(total) tasks done — finish them all to unlock!")
                    .font(Typography.font(12, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .kidContentColumn(kid.contentMaxWidth)
    }
}
