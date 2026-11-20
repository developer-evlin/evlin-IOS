import SwiftUI

struct TabletRootView: View {
    @Environment(SessionManager.self) private var session

    var onSwitchMode: () -> Void
    @State private var tab = DemoMode.kidTab ?? 0
    @State private var tasks = TabletData.tasks
    // Lifted up from ScreenTabletHome so the Ring tab's tokens can open the
    // same task detail flow — both tabs share this one `tasks` array, so
    // completing/redoing a task from either place needs to land in the
    // same source of truth rather than each tab keeping its own copy.
    @State private var selectedTask: KidTask?
    /// The first look round: it moves between the tabs as it goes.
    @ObservedObject private var kidTour = KidTour.shared

    // Computed properties pulling live data from the session store
    private var activeChild: Child? {
        if let id = session.activeChildId {
            return FamilyStore.children.first(where: { $0.id == id })
        }
        return FamilyStore.children.first
    }
    
    private var childName: String {
        activeChild?.name ?? "Child"
    }
    
    private var usedMin: Int {
        activeChild?.usageTodayMin ?? 0
    }
    
    private var limitMin: Int {
        activeChild?.dailyLimitMin ?? 120
    }

    @State private var onBreakUntil: Date?


    // "Your tasks for today" intro — shown once per app session, before the
    // kid sees their list, framing the day ahead. Purely a session flag (no
    // persistence anywhere else in this prototype either).
    @State private var showDayIntro = DemoMode.kidTab == nil && !DemoMode.kidTour
    // The phone just unlocked (the last task approved, or a parent
    // unlocking it by hand): the padlock opens and the play time shows.
    @State private var showUnlocked = false

    // Gates the actual unlock — must only count a real parent decision
    // (approved/bypassed), never .review. task.done alone means "submitted
    // or resolved" (kept inclusive of .review on purpose, so a turned-in
    // task still *looks* done on the task list instead of showing a
    // separate "awaiting approval" state — see ScreenTabletHome), which is
    // exactly the wrong thing to gate a lock on: it used to unlock the
    // phone the moment every task was *submitted*, with zero parent
    // approval actually required.
    private var approvedCount: Int { tasks.filter(\.approved).count }
    // Sent in or approved: once it's every task, the top bar says they're
    // all turned in and waiting, instead of asking for more work.
    private var submittedCount: Int { tasks.filter(\.done).count }
    // Delegates to the one derived-state function rather than answering here.
    // Real enforcement reads that same function from a separate process, and
    // a View-local answer couldn't be shared with it — two implementations of
    // "is it locked" that can disagree is the worst outcome for a lock.
    //
    // It also covers more than this line used to: a manual lock counts too.
    private var locked: Bool {
        _ = SyncState.shared.version
        guard let childId = session.activeChildId else { return approvedCount < tasks.count }
        return LocalStore.shared.enforcementState(childId: childId).isLocked
    }

    private var minutesLeft: Int { max(0, limitMin - usedMin) }
    private var onBreak: Bool { if let until = onBreakUntil { return Date() < until } else { return false } }

    /// Today's tasks from the phone's database -> the kid list, keeping the
    /// kid-only extras (photo count, note) already held for the same task.
    private func loadTasksFromStore() {
        guard let childId = session.activeChildId else { return }
        let existing = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        tasks = TaskStore.tasks(for: childId)
            .filter { $0.dueDate == nil || Calendar.current.isDateInToday($0.dueDate!) }
            .map { t in
                var k = existing[t.id] ?? KidTask(occurrenceId: t.occurrenceId, id: t.id, title: t.title,
                                                 iconTaskId: t.id, due: t.dueLabel, done: false, desc: t.description)
                k.occurrenceId = t.occurrenceId
                k.title = t.title
                k.emoji = t.shownEmoji
                k.desc = t.description
                k.needsPhoto = t.needsPhoto
                k.due = t.dueLabel
                k.done = t.state == .done || t.state == .review || t.state == .bypassed
                k.pendingApproval = t.state == .review || t.state == .bypass
                k.approved = t.state == .done || t.state == .bypassed
                k.bypassRequested = t.state == .bypass || t.state == .bypassed
                k.bypassNote = k.bypassRequested ? t.note : nil
                k.redoRequested = t.redoNote != nil
                k.redoNote = t.redoNote
                // Sent back: what was sent in is discarded, so the task
                // starts over with no photos counted from before.
                if k.redoRequested {
                    k.submittedPhotoCount = 0
                    k.submissionNote = nil
                }
                k.skipDeclinedNote = t.skipDeclinedNote
                return k
            }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // No Settings tab here — its only content was the Parent
                // Controls request, so a whole bottom-nav slot represented a
                // single feature rather than an actual settings section
                // (unlike, say, Telegram's Settings, which is genuinely its
                // own place). That access point now lives behind a small
                // gear icon in this tab's own toolbar (see ScreenTabletHome)
                // instead of being mistaken for real settings.
                // Tasks (what opens the iPad) and Goals (what they're
                // working toward, apart from the lock).
                TabView(selection: $tab) {
                    ScreenTabletHome(tasks: $tasks, onSwitchMode: onSwitchMode, onSelectTask: { selectedTask = $0 },
                                     topBar: AnyView(PlayTimeTopBar(minutesLeft: minutesLeft, minutesMax: limitMin, locked: locked, done: approvedCount, turnedIn: submittedCount, total: tasks.count, onBreak: onBreak)))
                        .withConnectionPill(kid: true)
                        .tabItem { Label("Tasks", systemImage: "checkmark.circle.fill") }
                        .tag(0)
                    ScreenTabletGoals()
                        .withConnectionPill(kid: true)
                        .tabItem { Label("Habits", systemImage: "star.fill") }
                        .tag(1)
                }
                .tint(KidTheme.tabTint)
                .toolbarBackground(KidTheme.cream, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
            .background(EPaperBackground())

            if showDayIntro {
                TaskDayIntroOverlay(childName: childName, taskCount: tasks.count) {
                    withAnimation(.easeOut(duration: 0.3)) { showDayIntro = false }
                }
                .transition(.opacity)
            }

            // The first look round, over the tabs too (after the day's intro).
            KidTourView()

            if showUnlocked {
                PhoneUnlockedOverlay(minutes: minutesLeft) {
                    withAnimation(.easeOut(duration: 0.3)) { showUnlocked = false }
                }
                .transition(.opacity)
            }
        }
        // Locked to unlocked, whatever unlocked it. Only a change counts: a
        // phone that opens already unlocked doesn't replay it.
        // The first look round starts once the day's intro is gone; each step
        // shows its own tab.
        .onChange(of: showDayIntro, initial: true) { _, intro in
            guard !intro, !showUnlocked else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                KidTour.shared.startIfNew()
            }
        }
        .onChange(of: kidTour.step) { _, step in
            if let step, step.tab != tab { withAnimation(.easeOut(duration: 0.25)) { tab = step.tab } }
        }
        .onChange(of: locked) { was, now in
            if was && !now { withAnimation(.easeInOut(duration: 0.25)) { showUnlocked = true } }
        }
        .task {
            if DemoMode.kidUnlock {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { showUnlocked = true }
            }
        }
        // A write the outbox couldn't deliver (the parent side shows the
        // same message in ParentRootView).
        .alert("Couldn't send", isPresented: Binding(get: { SyncState.shared.writeError != nil },
                                                     set: { if !$0 { SyncState.shared.writeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(SyncState.shared.writeError ?? "")
        }
        // Offline, or Evlin not answering: each tab shows the same quiet
        // pill as the parent's, in the kid's words (withConnectionPill).
        // Load what the parent assigned, now and whenever a sync lands.
        // hydrateIfNeeded first: populates FamilyStore/TaskStore from the
        // local cache before the network sync below has any chance to
        // land, so a fully offline launch (or a slow one) shows real,
        // previously-synced data immediately instead of an empty screen —
        // it's a no-op once the real sync has already populated this child.
        .onAppear {
            LocalStore.shared.hydrateIfNeeded()
            loadTasksFromStore()
            if DemoMode.kidOpenTask { selectedTask = tasks.first { !$0.done } }
            if DemoMode.kidOpenSent { selectedTask = tasks.first { $0.pendingApproval && !$0.bypassRequested } }
        }
        // Follows the database: the kid's own submit or skip, and every
        // sync (LiveUpdates syncs the moment the backend says something
        // changed; RootView on launch and on every return to the
        // foreground).
        .onChange(of: TaskStore.tasks(for: session.activeChildId ?? "")) { _, _ in loadTasksFromStore() }
        .fullScreenCover(item: $selectedTask) { task in
            TaskDetailView(task: task, onComplete: { photoCount, note, photoIds in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].submittedPhotoCount = photoCount
                    tasks[i].submissionNote = note
                }
                // Into the database (the list follows from it: sent in,
                // waiting on a parent), then out through the outbox, naming
                // the photos: it waits there until they're uploaded, and
                // the screen waits for the server's yes.
                guard let occId = task.occurrenceId, let childId = session.activeChildId else { return nil }
                LocalStore.shared.mirrorOccurrence(id: occId, status: "submitted")
                return Outbox.send(APIClient.Write.submitTask(occurrenceId: occId, bypassNote: note, photoIds: photoIds),
                                   occurrenceId: occId, taskId: task.id, childId: childId, label: "Your task")
            }, onRequestBypass: { reason in
                if let occId = task.occurrenceId, let childId = session.activeChildId {
                    let note = reason.isEmpty ? nil : reason
                    LocalStore.shared.mirrorOccurrence(id: occId, bypassRequested: true, bypassNote: note)
                    Outbox.send(APIClient.Write.requestBypass(occurrenceId: occId, note: note),
                                occurrenceId: occId, taskId: task.id, childId: childId, label: "Your request")
                }
            })
        }
    }

}

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
            EPaperBackground()

            VStack(spacing: 22) {
                Spacer()

                TasksTodayArt()
                    .frame(width: kid.of(200, 248), height: kid.of(200, 248))
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
                        .font(KidTheme.buttonFont(18))
                        .foregroundStyle(KidTheme.paperInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                }
                .buttonStyle(KidRaisedButtonStyle.paper())
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

// The phone has just unlocked: a padlock pops in, wiggles like a key
// turning, swings its shackle open and turns green as rays burst out.
private struct PhoneUnlockedOverlay: View {
    var minutes: Int
    var onContinue: () -> Void

    @State private var textIn = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private var timeLabel: String {
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        let remainingMinutes = m == 1 ? "1 minute" : "\(m) minutes"
        if h > 0, m > 0 { return "\(hours) and \(remainingMinutes)" }
        if h > 0 { return hours }
        return remainingMinutes
    }

    var body: some View {
        ZStack {
            EPaperBackground()

            VStack(spacing: 24) {
                Spacer()
                PadlockUnlock()
                    .frame(width: kid.of(240, 300), height: kid.of(240, 300))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Your phone is unlocked")
                        .font(Typography.display(kid.of(34, 40), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text(minutes > 0 ? "\(timeLabel) of screen time is available" : "Your apps are open")
                        .font(Typography.font(kid.of(18, 21), weight: .bold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                .multilineTextAlignment(.center)
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn ? 0 : 12)
                Spacer()
                Button(action: onContinue) {
                    Text("Continue")
                        .font(KidTheme.buttonFont(19))
                        .foregroundStyle(KidTheme.paperInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                }
                .buttonStyle(KidRaisedButtonStyle.paper())
                .frame(maxWidth: 420)
                .opacity(textIn ? 1 : 0)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(1.15)) { textIn = true }
        }
    }
}

/// A padlock opening, drawn on a 200-point square. Plays once on appear;
/// Reduce Motion shows it open.
private struct PadlockUnlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var popped = false
    @State private var wiggle: Double = 0
    @State private var open = false
    @State private var rays: CGFloat = 0
    @State private var raysOpacity: Double = 0

    private let amber = Color(hex: "FFB938")
    private let amberDeep = Color(hex: "E8962C")

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(KidTheme.greenTint)
                    .frame(width: 170 * s, height: 170 * s)
                    .offset(x: 15 * s, y: 22 * s)
                    .scaleEffect(open ? 1 : 0.85)

                // Rays bursting out once it opens.
                ForEach(0..<10, id: \.self) { i in
                    let angle = Double(i) / 10 * 2 * .pi
                    Capsule()
                        .fill(i.isMultiple(of: 2) ? KidTheme.green : Color(hex: "FFC93C"))
                        .frame(width: 16 * s, height: 5 * s)
                        .rotationEffect(.radians(angle))
                        .position(x: (100 + cos(angle) * (62 + 34 * rays)) * s,
                                  y: (110 + sin(angle) * (62 + 34 * rays)) * s)
                        .opacity(raysOpacity)
                }

                Group {
                    // The shackle: lifts out of the body and swings open
                    // round its left leg.
                    Path { p in
                        p.move(to: CGPoint(x: 72 * s, y: 100 * s))
                        p.addLine(to: CGPoint(x: 72 * s, y: 68 * s))
                        p.addArc(center: CGPoint(x: 100 * s, y: 68 * s), radius: 28 * s,
                                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                        p.addLine(to: CGPoint(x: 128 * s, y: 100 * s))
                    }
                    .stroke(open ? KidTheme.greenDeep : Color(hex: "B8C2BC"), style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
                    .offset(y: open ? -16 * s : 0)
                    .rotationEffect(.degrees(open ? -28 : 0), anchor: UnitPoint(x: 0.36, y: 0.5))

                    // The body, amber while locked, green once open.
                    // Flat colour, no gradient or shading: a 2D sticker look.
                    RoundedRectangle(cornerRadius: 20 * s, style: .continuous)
                        .fill(open ? KidTheme.green : amber)
                        .frame(width: 104 * s, height: 82 * s)
                        .offset(x: 48 * s, y: 92 * s)
                    // The keyhole, one flat shape in the body's darker shade.
                    Circle().fill(open ? KidTheme.greenDeep : amberDeep)
                        .frame(width: 20 * s, height: 20 * s)
                        .offset(x: 90 * s, y: 114 * s)
                    Capsule().fill(open ? KidTheme.greenDeep : amberDeep)
                        .frame(width: 9 * s, height: 26 * s)
                        .offset(x: 95.5 * s, y: 124 * s)
                }
                .rotationEffect(.degrees(wiggle), anchor: UnitPoint(x: 0.5, y: 0.85))
            }
            .frame(width: 200 * s, height: 200 * s, alignment: .topLeading)
            .scaleEffect(shown ? (popped ? 1 : 1.12) : 0.2)
            .opacity(shown ? 1 : 0)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: play)
    }

    private func play() {
        guard !reduceMotion else { shown = true; popped = true; open = true; return }
        // Pops up: past full size, then settles back, flat in the plane.
        withAnimation(.spring(duration: 0.3, bounce: 0.5)) { shown = true }
        withAnimation(.spring(duration: 0.25, bounce: 0.3).delay(0.22)) { popped = true }
        // The key turning: a quick wiggle before it gives.
        withAnimation(.easeInOut(duration: 0.08).repeatCount(4, autoreverses: true).delay(0.45)) { wiggle = 6 }
        withAnimation(.easeOut(duration: 0.08).delay(0.78)) { wiggle = 0 }
        withAnimation(.spring(duration: 0.45, bounce: 0.45).delay(0.85)) { open = true }
        // The rays fly out and fade as they go. Their own opacity, not one
        // worked out from `rays`: that would read only its final value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            raysOpacity = 1
            withAnimation(.easeOut(duration: 0.7)) { rays = 1 }
            withAnimation(.easeIn(duration: 0.45).delay(0.3)) { raysOpacity = 0 }
        }
    }
}

private struct PlayTimeTopBar: View {
    var minutesLeft: Int
    var minutesMax: Int
    var locked: Bool
    /// Approved, the parent's count.
    var done: Int
    /// Sent in or approved.
    var turnedIn: Int
    var total: Int
    var onBreak: Bool = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private var frac: Double {
        locked ? 0 : max(0, min(1, minutesMax > 0 ? Double(minutesLeft) / Double(minutesMax) : 0))
    }
    // Locked with tasks still to finish: the bar shows the goal, as the
    // parent's does. Approved fills solid green, sent in and waiting for a
    // grown-up a lighter green, so every task done moves it.
    private var showsTasks: Bool { locked && !onBreak && total > 0 && done < total }
    private func part(_ n: Int) -> Double { total > 0 ? max(0, min(1, Double(n) / Double(total))) : 0 }
    /// Play time's colour: the kid's bright button green, amber in the last
    /// ten minutes and when locked (2026-11-15, the user's call: "this
    /// progress bar needs to improve"; a dull deep green #25924A, 8pt, on a
    /// pale green track before).
    private var lowOnTime: Bool { !locked && !onBreak && minutesLeft <= 10 }
    private var accent: Color { locked || lowOnTime ? Color(hex: "F0A020") : KidTheme.paperButton }
    /// The bar's track: Apple's light grey on the off-white card, the line
    /// colour at night.
    private static let track = Color(light: "EFEFF4", warm: "353A42")
    private static let barHeight: CGFloat = 12

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                // The icon on its own soft tile, so it doesn't float on the card.
                RoundedRectangle(cornerRadius: 12)
                    .fill(locked || lowOnTime ? Color(light: "FFF1D6", warm: "3A3226") : KidTheme.greenTint)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: locked ? "lock.fill" : "clock.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(accent))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(showsTasks ? "TASKS TODAY" : "PLAY TIME TODAY")
                            .font(Typography.font(11, weight: .bold)).tracking(0.4).foregroundStyle(KidTheme.inkSoft)
                        Spacer()
                        if showsTasks {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(done)")
                                    .font(Typography.display(20, weight: .heavy))
                                    .foregroundStyle(done > 0 ? KidTheme.greenDeep : KidTheme.ink)
                                    .contentTransition(.numericText())
                                Text("of \(total)")
                                    .font(Typography.display(16, weight: .bold)).foregroundStyle(KidTheme.inkSoft)
                            }
                        } else {
                            Text(onBreak ? "On a break" : (locked ? "Locked" : "\(minutesLeft / 60 > 0 ? "\(minutesLeft / 60)h " : "")\(minutesLeft % 60)m left"))
                                .font(Typography.display(18, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        }
                    }
                    GeometryReader { geo in
                        let h = Self.barHeight
                        Capsule().fill(Self.track).frame(height: h)
                            .overlay(alignment: .leading) {
                                if showsTasks {
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(KidTheme.paperButton.opacity(0.4))
                                            .frame(width: geo.size.width * part(turnedIn), height: h)
                                        Capsule().fill(KidTheme.paperButton)
                                            .frame(width: geo.size.width * part(done), height: h)
                                    }
                                } else {
                                    // Never a sliver: a little time left still shows as a dot.
                                    Capsule().fill(accent)
                                        .frame(width: frac > 0 ? max(h, geo.size.width * frac) : 0, height: h)
                                }
                            }
                    }
                    .frame(height: Self.barHeight)
                    .animation(.spring(duration: 0.5, bounce: 0), value: frac)
                }
            }
            .padding(14)
            .background(KidTheme.cream)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.line))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            // Each task done moves the bar along, not a jump.
            .animation(.spring(duration: 0.5, bounce: 0), value: done)
            .animation(.spring(duration: 0.5, bounce: 0), value: turnedIn)

            if locked {
                // Everything sent in but not all checked: still locked, and
                // the only thing left is the parent's review, so it says so
                // instead of asking for more work.
                Text(turnedIn == total
                     ? "All turned in! Waiting for your parent to check them."
                     : "\(total - turnedIn) more to go, then play time unlocks!")
                    .font(Typography.font(12, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
            }
        }
        // On iPad, Home places it in its own page, full width.
        .padding(.horizontal, kid.isRegular ? 0 : 22)
        .padding(.top, kid.isRegular ? 0 : 22)
    }
}
