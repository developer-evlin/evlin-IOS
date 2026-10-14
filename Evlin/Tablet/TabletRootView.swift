import SwiftUI

struct TabletRootView: View {
    @Environment(SessionManager.self) private var session

    var onSwitchMode: () -> Void
    @State private var tab = 0
    @State private var tasks = TabletData.tasks
    // Lifted up from ScreenTabletHome so the Ring tab's tokens can open the
    // same task detail flow — both tabs share this one `tasks` array, so
    // completing/redoing a task from either place needs to land in the
    // same source of truth rather than each tab keeping its own copy.
    @State private var selectedTask: KidTask?

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
    @State private var showDayIntro = true
    // The finish-all-tasks celebration -> screen-time reveal, triggered the
    // moment doneCount reaches the total. Reset if a task gets un-done (a
    // parent Redo) so finishing everything again replays the payoff.
    @State private var celebrationStage: CelebrationStage?
    @State private var didCelebrateThisCompletion = false

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
                k.desc = t.description
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
                if tab == 0 {
                    PlayTimeTopBar(minutesLeft: minutesLeft, minutesMax: limitMin, locked: locked, done: approvedCount, turnedIn: submittedCount, total: tasks.count, onBreak: onBreak)
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
                    ScreenTabletLibrary()
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                        .tag(2)
                    ScreenTabletCalendar()
                        .tabItem { Label("Calendar", systemImage: "calendar") }
                        .tag(1)
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
                TaskDayIntroOverlay(childName: childName, taskCount: tasks.count) {
                    withAnimation(.easeOut(duration: 0.3)) { showDayIntro = false }
                }
                .transition(.opacity)
            }

            if let stage = celebrationStage {
                TaskCompletionOverlay(stage: stage, childName: childName, limitMin: limitMin) {
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
        .onChange(of: approvedCount) { _, newValue in
            if newValue == tasks.count, !tasks.isEmpty, !didCelebrateThisCompletion {
                didCelebrateThisCompletion = true
                withAnimation(.easeInOut(duration: 0.25)) { celebrationStage = .congrats }
            } else if newValue < tasks.count {
                didCelebrateThisCompletion = false
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
        // Same gap as the parent side's syncErrorBanner (ParentRootView) —
        // this used to be console-print-only, so this device could sit on
        // stale data (or the "Syncing…" placeholder never resolving) with
        // no visible sign anything was wrong. The 10s poll below retries
        // on its own; this just makes a stuck attempt visible.
        .overlay(alignment: .top) { syncErrorBanner }
        // Load what the parent assigned, now and whenever a sync lands.
        // hydrateIfNeeded first: populates FamilyStore/TaskStore from the
        // local cache before the network sync below has any chance to
        // land, so a fully offline launch (or a slow one) shows real,
        // previously-synced data immediately instead of an empty screen —
        // it's a no-op once the real sync has already populated this child.
        .onAppear {
            LocalStore.shared.hydrateIfNeeded()
            loadTasksFromStore()
        }
        // Follows the database: the kid's own submit or skip, and every
        // sync (LiveUpdates syncs the moment the backend says something
        // changed; RootView on launch and on every return to the
        // foreground).
        .onChange(of: TaskStore.tasks(for: session.activeChildId ?? "")) { _, _ in loadTasksFromStore() }
        .fullScreenCover(item: $selectedTask) { task in
            TaskDetailView(task: task, onComplete: { photoCount, note in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].submittedPhotoCount = photoCount
                    tasks[i].submissionNote = note
                }
                // Into the database (the list follows from it: sent in,
                // waiting on a parent), then out through the outbox.
                if let occId = task.occurrenceId, let childId = session.activeChildId {
                    LocalStore.shared.mirrorOccurrence(id: occId, status: "submitted")
                    Outbox.send(APIClient.Write.submitTask(occurrenceId: occId, bypassNote: note),
                                occurrenceId: occId, taskId: task.id, childId: childId, label: "Your task")
                }
                // The task screen stays open: it shows "Evidence submitted"
                // next, and the kid leaves with "Back to today".
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

    @ViewBuilder
    private var syncErrorBanner: some View {
        if let message = SyncState.shared.syncError {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                Text(message).font(.footnote).lineLimit(2)
                Spacer(minLength: 8)
                Button { SyncState.shared.syncError = nil } label: {
                    Image(systemName: "xmark")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: SyncState.shared.syncError)
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
                // Everything sent in but not all checked: still locked, and
                // the only thing left is the parent's review, so it says so
                // instead of asking for more work.
                Text(turnedIn == total
                     ? "All turned in! Waiting for your parent to check them."
                     : "\(done) of \(total) tasks done — finish them all to unlock!")
                    .font(Typography.font(12, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .kidContentColumn(kid.contentMaxWidth)
    }
}
