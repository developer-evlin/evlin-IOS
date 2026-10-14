import SwiftUI
import UIKit

// The selected child's space: Home's whole content (see ScreenHome, whose
// avatars switch which child this shows).
struct ScreenProfile: View {
    var childId: String

    @ObservedObject private var child: Child
    // Read from the phone's database (TaskStore), never copied: a change
    // made anywhere (here, the review deck, a sync) is on this list the
    // moment it's saved.
    private var tasks: [ChildTask] { TaskStore.tasks(for: childId) }
    // Opens the review deck on a task. Home presents it, not this page:
    // this page redraws whenever anything above it updates, and a deck
    // presented from here was rebuilt along with it, dropping the edit sheet
    // the moment it opened.
    var onReview: (_ taskId: String) -> Void
    // Was a menu offering "Add Task" or "Add Rule" — rules (including
    // downtime) now come from chat instead, so the "+" goes straight to
    // adding a task, no intermediate menu with a single choice on it.
    @State private var showAddTask = false
    // A task on the Tomorrow tab, open in the edit form. Tomorrow's tasks
    // have nothing to review yet, so tapping one edits it instead.
    @State private var editingTomorrowTask: ChildTask?
    @State private var showScreenTime = false
    @State private var showUnlockConfirm = false
    @State private var showGrantTimeSheet = false
    // Drives the brief "verifying it's you" beat between tapping Approve in
    // approvalBanner and actually flipping child.parentApprovalStatus — see
    // ParentApprovalVerifyingOverlay below.
    @State private var showApprovalVerify = false
    @ObservedObject private var billing = BillingState.shared
    @State private var isUpgrading = false
    // Pops the trial-exhausted upgrade prompt up the moment this profile
    // opens (see TrialExhaustedPopupCard) — set once on appear, not tied to
    // child.trialExhausted directly, so dismissing it ("Not now") doesn't
    // immediately reappear from some other body re-evaluation.
    @State private var showTrialPopup = false
    @State private var showProtectionSetupPopup = false
    // Today / Tomorrow tabs over the task list.
    @State private var showingTomorrow = false
    // The page the Today / Tomorrow pager is on.
    @State private var pagerTomorrow: Bool? = false
    @Namespace private var dayTabs
    // A success tap as a new task is saved.
    @State private var addedTick = 0
    // Rings ticked a moment ago, drawn done while their rows wait to move.
    @State private var justChecked: Set<String> = []
    @State private var checkedTick = 0
    @State private var undoneTick = 0
    @State private var landedTick = 0
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var adaptive: ParentAdaptive { ParentAdaptive(hSizeClass) }

    init(childId: String, onReview: @escaping (_ taskId: String) -> Void) {
        self.childId = childId
        self.onReview = onReview
        let c = FamilyStore.child(childId)
        _child = ObservedObject(wrappedValue: c)
    }

    // A task due on some other day (tomorrow, via the New Task date
    // picker) isn't part of today's list at all — nil dueDate (every
    // pre-seeded mock task) always counts as visible today.
    private func isDueToday(_ task: ChildTask) -> Bool { task.isDueToday }

    private static func dueDateString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private static func dueTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private var todaysTasks: [ChildTask] { tasks.filter(isDueToday) }
    private var doneCount: Int { todaysTasks.filter { $0.state == .done }.count }


    var body: some View {
        // Re-renders on a change to the family (FamilyStore isn't observed);
        // tasks are, through TaskStore.
        let _ = SyncState.shared.version
        // The status and the Today / Tomorrow tabs stay put; only the list
        // below them scrolls (and bounces).
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                statusCard
                    .padding(.top, 6)
                dayTabBar
                    .padding(.top, 18)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .parentContentColumn(adaptive.contentMaxWidth)

            // Today and Tomorrow side by side in the system's own paging
            // scroll view: iOS tells a sideways swipe from a scroll itself,
            // with its own physics, so the two never fight.
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach([false, true], id: \.self) { tomorrow in
                            ScrollView {
                                dayList(tomorrow: tomorrow)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 24)
                                    .parentContentColumn(adaptive.contentMaxWidth)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(tomorrow)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $pagerTomorrow)
            }
            .onChange(of: pagerTomorrow) { _, t in
                guard let t, t != showingTomorrow else { return }
                showingTomorrow = t
            }
        }
        .accessibilityAction(named: "Show tomorrow") { showDay(tomorrow: true) }
        .accessibilityAction(named: "Show today") { showDay(tomorrow: false) }
        // Adding a task feels like approving one: success, as it's saved.
        .sensoryFeedback(.success, trigger: addedTick)
        // A selection tick, like a segmented control, when the day changes.
        .sensoryFeedback(.selection, trigger: showingTomorrow)
        .sensoryFeedback(.success, trigger: checkedTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: landedTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: undoneTick)
        .background(EColor.surface)
        // A safeAreaInset (not a ZStack + guessed bottom padding) reserves
        // real layout space for the FAB, so the scroll content's last row —
        // e.g. a rule's description/toggle — can never end up rendered
        // underneath it, regardless of how long or short the list is.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button { showAddTask = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        // Ink, not green: on Home green means "the phone is
                        // open" (the switch, the time bar).
                        .background(EColor.primary)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a task")
            }
            .padding(.trailing, 20)
            .padding(.bottom, 16)
        }
        // A floating card (matching this app's other confirm-card designs),
        // not a native .alert — sits over the whole screen so it can never
        // end up eclipsed by content, dismissible by tapping the dimmed
        // backdrop as well as its own Cancel button.
        .overlay {
            if showUnlockConfirm {
                UnlockConfirmCard(
                    childName: child.name,
                    remaining: todaysTasks.count - doneCount,
                    onUnlock: {
                        applyGateOverride()
                        child.timeLeft = formatMinutes(child.dailyLimitMin)
                        child.timePct = 100
                        withAnimation(.easeOut(duration: 0.2)) { showUnlockConfirm = false }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.2)) { showUnlockConfirm = false } }
                )
            }
        }
        // Same floating-card-over-scrim language as UnlockConfirmCard —
        // was a native .sheet (a full-width bottom sheet with no visible
        // dimmed backdrop), which read as a different, heavier kind of
        // screen than this app's other confirm moments.
        .overlay {
            if showGrantTimeSheet {
                GrantExtraTimeSheet(
                    childName: child.name,
                    dailyLimitMin: child.dailyLimitMin,
                    usageTodayMin: child.usageTodayMin,
                    onGrant: { minutes in
                        // `minutes` here is the *additional* amount ("Give
                        // 30 more minutes") — this used to just overwrite
                        // child.timeLeft with that literal string, which
                        // read as the pool being SET to 30 minutes rather
                        // than increased by 30. Now posts a real, signed
                        // ledger entry (see time_grants); the sync its live
                        // update brings corrects the display to the real
                        // new total within a moment.
                        applyGateOverride()
                        Outbox.send(APIClient.Write.createTimeGrant(childId: child.id, minutes: minutes),
                                    childId: child.id, label: "Extra time")
                        withAnimation(.easeOut(duration: 0.2)) { showGrantTimeSheet = false }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.2)) { showGrantTimeSheet = false } }
                )
            }
        }
        // A floating card over a dimmed scrim, matching UnlockConfirmCard
        // above — was an inline banner sitting in the scroll content, which
        // undersold how time-sensitive it is (a kid is blocked, waiting on
        // this) and could scroll out of view entirely.
        .overlay {
            if child.parentApprovalStatus == .pending {
                approvalBanner
            }
        }
        // The passwordless "verifying it's you" beat — kicked off by
        // approvalBanner's Approve button, resolves by flipping
        // child.parentApprovalStatus to .approved once it finishes.
        .overlay {
            if showApprovalVerify {
                ParentApprovalVerifyingOverlay {
                    withAnimation(.easeOut(duration: 0.2)) {
                        child.parentApprovalStatus = .approved
                        showApprovalVerify = false
                    }
                }
            }
        }
        .overlay {
            if showTrialPopup {
                TrialExhaustedPopupCard(
                    childName: child.name,
                    isUpgrading: isUpgrading,
                    onUpgrade: {
                        Task {
                            isUpgrading = true
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            isUpgrading = false
                            withAnimation { billing.isPlus = true; showTrialPopup = false }
                        }
                    },
                    onDismiss: { withAnimation(.easeOut(duration: 0.2)) { showTrialPopup = false } }
                )
            }
        }
        .overlay {
            if showProtectionSetupPopup {
                ProtectionSetupNeededCard(
                    childName: child.name,
                    onOpenSettings: {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    },
                    onDismiss: { withAnimation(.easeOut(duration: 0.2)) { showProtectionSetupPopup = false } }
                )
            }
        }
        // This page sits under Home's header, so its cards' backdrops stop
        // at the header's edge. Home reads this and dims the header to match.
        .preference(key: HomeScrimKey.self, value: cardScrimOpacity)
        .task {
            if child.trialExhausted { withAnimation(.easeOut(duration: 0.2)) { showTrialPopup = true } }
            if child.needsProtectionSetup { withAnimation(.easeOut(duration: 0.2)) { showProtectionSetupPopup = true } }
        }
        .sheet(isPresented: $showScreenTime) {
            Group {
            ChildScreenTimeSheet(child: child)
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingTomorrowTask) { task in
            Group {
            EditTaskReviewSheet(
                task: task,
                onSave: { updated in
                    TaskEdits.save(updated, clearDueTime: task.dueLabel != nil && updated.dueLabel == nil)
                    editingTomorrowTask = nil
                },
                onDelete: {
                    // The sheet slides away first, then the row leaves.
                    editingTomorrowTask = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + TaskEdits.sheetCloseDelay) {
                        withAnimation(.spring(duration: 0.35, bounce: 0)) { TaskEdits.delete(task) }
                    }
                },
                onCancel: { editingTomorrowTask = nil }
            )
            .presentationDetents([.large])
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddTask) {
            Group {
            AddTaskSheet(child: child, day: selectedDay, onCreate: { created in
                showAddTask = false
                let day = selectedDay
                // Saved to the phone's database just as the sheet finishes
                // sliding away, so the row lands in its sorted place then;
                // the outbox sends it.
                addedTick += 1   // felt at the tap, as for an approval
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.snappy(duration: 0.3)) {
                        _ = TaskEdits.create(
                            childId: childId,
                            title: created.title,
                            instructions: created.description,
                            recurrence: created.repeats,
                            category: created.category,
                            // Due on the chosen day; at a time only when the
                            // parent added a deadline.
                            dueTime: created.dueLabel == nil ? nil : created.dueDate.map { Self.dueTimeString($0) },
                            dueDate: Self.dueDateString(day)
                        )
                    }
                }
            }, onCancel: { showAddTask = false })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents([.large])
            .presentationBackground(EColor.surface)
        }
            .presentationDragIndicator(.visible)
        }
    }

    // Replaces the old kid-device PIN gate: a kid tapping "Parent controls"
    // sets child.parentApprovalStatus to .pending (see ScreenTabletHome) and
    // this is the only place that can clear it — there's no code to guess,
    // just presence + a tap from inside the kid's own profile. A floating
    // card over a dimmed scrim (matching UnlockConfirmCard's style below),
    // not an inline banner in the scroll content — a kid waiting on this
    // shouldn't be easy to scroll past without noticing.
    private var approvalBanner: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { child.parentApprovalStatus = .none } }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SecurityLottieView(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(child.name) wants Parent Controls")
                                .font(Typography.font(17, weight: .heavy))
                                .foregroundStyle(EColor.onSurface)
                            Text("Passwordless approval")
                                .font(Typography.font(12, weight: .semibold))
                                .foregroundStyle(EColor.onSurfaceVariant)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Nothing happens on their device until you confirm it's you.")
                        .font(Typography.font(14, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 10) {
                        cardButton("Approve", tint: Brand.greenDeep, filled: true) {
                            withAnimation(.easeOut(duration: 0.2)) { showApprovalVerify = true }
                        }
                        cardButton("Not now", tint: EColor.onSurfaceVariant, filled: false) {
                            withAnimation(.easeOut(duration: 0.2)) { child.parentApprovalStatus = .none }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private func cardButton(_ label: String, tint: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.font(15, weight: .bold))
                .foregroundStyle(filled ? .white : tint)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(filled ? tint : .white)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(filled ? .clear : EColor.outlineVariant, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // The backdrop opacity of whichever card is showing over this page (all
    // of them dim with black at these strengths), or 0 when none is.
    private var cardScrimOpacity: Double {
        if showApprovalVerify { return 0.36 }
        if showUnlockConfirm || showGrantTimeSheet || showTrialPopup || showProtectionSetupPopup
            || child.parentApprovalStatus == .pending { return 0.32 }
        return 0
    }

    // MARK: - Today's counts

    // Every task that lands on tomorrow, repeats included (TaskStore builds
    // this from the repeat rules at sync). Filtering `tasks` by date missed
    // every repeating task: its one entry carries today's date.
    private var tomorrowsTasks: [ChildTask] { TaskStore.tomorrowTasks(for: childId) }
    private var waitingForReview: [ChildTask] { todaysTasks.filter { $0.state == .review || $0.state == .bypass } }
    private var leftToDo: Int { todaysTasks.filter { $0.state == .pending || $0.state == .overdue }.count }

    // MARK: - Status header

    // The phone's state as one line: today's progress (or the time left, or
    // downtime) on the left, and a track that runs from it to the lock
    // button and wraps around it. Below, the one way into screen time:
    // blocked apps and the limit.
    private var statusCard: some View {
        VStack(spacing: 0) {
            StatusPathHeader(phase: statusPhase, childName: child.name, action: toggleLock)

            Button { showScreenTime = true } label: {
                HStack {
                    Text("View blocked apps & screen time limit")
                        .font(Typography.font(14, weight: .regular))
                        .foregroundStyle(StatusCardStyle.secondaryLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StatusCardStyle.tertiaryLabel)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressedOpacityStyle())
        }
    }

    // Today's finished tasks: approved, or a skip said yes to.
    private var finishedCount: Int { todaysTasks.filter { $0.state == .done || $0.state == .bypassed }.count }

    // The button says what a tap will do:
    // - open, time left: an open lock; a tap locks.
    // - locked by hand: a red lock; a tap opens it again.
    // - tasks still to do: progress and a red lock; a tap asks first.
    // - everything sent in, waiting on the parent: a green check; a tap
    //   approves them all, which opens the phone.
    // - out of time: a red lock; a tap asks how much longer.
    private var statusPhase: StatusPathHeader.Phase {
        switch child.status {
        case .downtime:
            return .downtime(until: child.downtimeUntil ?? "morning")
        case .unlocked:
            return child.timePct > 0
                ? .open(timeLeft: child.timeLeft, fraction: Double(child.timePct) / 100)
                : .timeUp
        case .locked, .lockedTasks:
            // Tasks still to do always show as progress ("2 tasks left"),
            // however the phone came to be locked.
            let total = todaysTasks.count
            if total > 0 && leftToDo > 0 { return .tasks(done: finishedCount, total: total) }
            if child.manualLock {
                return child.timePct > 0 ? .paused(timeLeft: child.timeLeft) : .timeUp
            }
            if !waitingForReview.isEmpty { return .ready(timeLeft: child.timeLeft) }
            return child.timePct > 0 ? .paused(timeLeft: child.timeLeft) : .timeUp
        }
    }

    // The same decisions the old Lock/Unlock button made: locking is
    // immediate; unlocking with tasks left asks first; with tasks done and
    // the day's time used up, it asks how much more.
    private func toggleLock() {
        switch statusPhase {
        case .open:
            // A manual lock is a pause, not time spent: whatever was left
            // comes back as-is on unlock.
            applyManualLock(locked: true)
        case .ready(_):
            approveAll()
        case .timeUp:
            withAnimation(.easeOut(duration: 0.2)) { showGrantTimeSheet = true }
        case .tasks:
            if leftToDo > 0 {
                withAnimation(.easeOut(duration: 0.2)) { showUnlockConfirm = true }
            } else {
                applyManualLock(locked: false)
            }
        case .paused:
            if leftToDo > 0 {
                withAnimation(.easeOut(duration: 0.2)) { showUnlockConfirm = true }
            } else {
                applyManualLock(locked: false)
            }
        case .downtime:
            break
        }
    }

    // Everything the kid sent in (or asked to skip), approved in one go:
    // with nothing left, the phone opens on its own.
    private func approveAll() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            for task in waitingForReview { TaskEdits.approve(task, childId: childId) }
        }
    }

    // Downtime is a schedule lock owned by the Downtime rule, not a manual
    // one — so unlike the Lock/Unlock button above, the header shows no
    // controls of its own while it's active. Toggling or deleting the
    // Downtime rule is what ends it (exitDowntimeIfActive, moved to
    // ChildSettingsSheet along with the rest of rule editing — see
    // ScreenSettings.swift).

    private func applyManualLock(locked: Bool) {
        child.manualLock = locked
        child.saveState(label: locked ? "Locking the phone" : "Unlocking the phone")
    }

    private func applyGateOverride() {
        child.manualLock = false
        child.taskGateOverride = true
        child.saveState(label: "Unlocking the phone")
    }
    

    // MARK: - Tasks (Today / Tomorrow, flat rows)

    private var dayTabBar: some View {
        HStack(spacing: 18) {
            dayTab("Today", on: !showingTomorrow) { showDay(tomorrow: false) }
            dayTab("Tomorrow", on: showingTomorrow) { showDay(tomorrow: true) }
        }
    }

    @ViewBuilder private func dayList(tomorrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if tomorrow {
                if tomorrowsTasks.isEmpty {
                    emptyLine("Nothing planned for tomorrow yet.")
                } else {
                    taskList([(nil, tomorrowsTasks)], isTomorrow: true)
                }
            } else if todaysTasks.isEmpty {
                emptyLine("Nothing left for today.")
            } else {
                // Grouped by what each needs, most urgent first: late, then
                // waiting on the parent, then still to do, then done. "To do"
                // gets a heading only when there's a group above it to tell
                // it apart from; on its own it's just the list.
                let overdue = todaysTasks.filter { $0.state == .overdue }
                let waiting = todaysTasks.filter { $0.state == .review || $0.state == .bypass }
                taskList([
                    ("Overdue", overdue),
                    ("Waiting for you", waiting),
                    (overdue.isEmpty && waiting.isEmpty ? nil : "To do", todaysTasks.filter { $0.state == .pending }),
                    ("Completed", todaysTasks.filter { $0.state == .done || $0.state == .bypassed }),
                ], isTomorrow: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The ring as a checkbox. Ticking completes the task (as Approve does):
    // the ring fills at once, then a beat later the row moves to Completed,
    // so the tick is seen before the list changes. Un-ticking a done task
    // sends it back to the kid as a to-do (as Redo does, with no note).
    private func toggleDone(_ task: ChildTask) {
        if task.state == .done || task.state == .bypassed {
            undoneTick += 1
            withAnimation(.spring(duration: 0.35, bounce: 0)) { TaskEdits.redo(task, note: "", childId: childId) }
            return
        }
        guard !justChecked.contains(task.id) else { return }
        checkedTick += 1
        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { _ = justChecked.insert(task.id) }
        // Held ticked for half a second so it's seen, then it leaves; a soft
        // tap as it lands in Completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                TaskEdits.approve(task, childId: childId)
                justChecked.remove(task.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { landedTick += 1 }
        }
    }

    // A tab tap: the pager slides to that day.
    private func showDay(tomorrow: Bool) {
        guard tomorrow != showingTomorrow else { return }
        withAnimation(.snappy(duration: 0.3)) {
            showingTomorrow = tomorrow
            pagerTomorrow = tomorrow
        }
    }

    // The list's lines: a section heading, or a task (with a hairline above
    // it unless it opens its section).
    private enum ListLine: Identifiable {
        case heading(String)
        case task(ChildTask, hairline: Bool, section: String)

        // A task's identity includes its section: changing section is
        // leaving one place and arriving in another, not a move.
        var id: String {
            switch self {
            case .heading(let title): return "heading-\(title)"
            case .task(let task, _, let section): return "\(section)-\(task.id)"
            }
        }
    }

    // All the sections as one list: small bold headings, then rows with
    // hairlines between them (not above a section's first), inset to start
    // under the text. A task that changes section (ticked off, sent back)
    // fades out where it was while the rows below close up, then fades in
    // at its new place, as Things and Reminders do; it never travels across
    // the list over the other rows, which is what looked glitchy.
    private func taskList(_ sections: [(String?, [ChildTask])], isTomorrow: Bool) -> some View {
        var lines: [ListLine] = []
        for (title, tasks) in sections where !tasks.isEmpty {
            if let title { lines.append(.heading(title)) }
            for (i, task) in tasks.enumerated() {
                lines.append(.task(task, hairline: i > 0, section: title ?? "list"))
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                switch line {
                case .heading(let title):
                    Text(title)
                        .font(Typography.font(15, weight: .bold))
                        .foregroundStyle(EColor.onSurface)
                        .padding(.top, 18)
                        .padding(.bottom, 2)
                        .transition(Self.lineTransition)
                case .task(let task, let hairline, _):
                    HomeTaskRow(task: task, color: child.color, isTomorrow: isTomorrow,
                                justChecked: justChecked.contains(task.id),
                                onRingTap: isTomorrow ? nil : { toggleDone(task) })
                        .overlay(alignment: .top) {
                            Rectangle().fill(HomeStyle.line).frame(height: 1).padding(.leading, 54)
                                .opacity(hairline ? 1 : 0)
                        }
                        .onTapGesture {
                            if isTomorrow { editingTomorrowTask = task } else { onReview(task.id) }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(isTomorrow ? "Edits this task" : "Opens this task")
                        .transition(Self.lineTransition)
                }
            }
        }
        // Every change to the list moves the same way, a tick here or a
        // change a sync brought, so nothing jumps.
        .animation(.spring(duration: 0.35, bounce: 0), value: lines.map(\.id))
    }

    // A line arriving fades in where it lands, once the lines around it
    // have finished moving (its space is kept from the start): shown at once,
    // the heading above slid down across it. A line leaving goes at once:
    // the rows below slide up into its place, and fading it out instead left
    // it see-through on top of the row moving in. (A ticked task's ring
    // already showed the tick for half a second before it leaves.)
    private static let lineTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.3)),
        removal: .identity
    )

    private func dayTab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(16, weight: .heavy))
                .foregroundStyle(on ? EColor.onSurface : HomeStyle.muted)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    if on {
                        Rectangle().fill(EColor.onSurface).frame(height: 2.5)
                            .matchedGeometryEffect(id: "dayTabUnderline", in: dayTabs)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // The day the + adds to: whichever of Today / Tomorrow is showing.
    private var selectedDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return showingTomorrow ? (Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today) : today
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.font(14, weight: .heavy))
            .foregroundStyle(HomeStyle.muted)
            .padding(.vertical, 14)
    }

}

// MARK: - Protection setup nudge (Leo's "PIN not set" prompt)

// Mirrors the tamper-proofing step from onboarding (ParentSetPasscodeV2Step)
// — without a device Screen Time passcode or Family Sharing, the kid can
// just turn Evlin off or delete it, so a profile missing that setup gets
// nudged here too, not just once during setup.
private struct ProtectionSetupNeededCard: View {
    var childName: String
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(EColor.danger)
                        Text("Protect Evlin from being removed")
                            .font(Typography.font(18, weight: .heavy))
                            .foregroundStyle(EColor.onSurface)
                    }

                    Text("\(childName) could turn off or delete Evlin at any time. Set a Screen Time passcode on \(childName)'s device, or enroll in Family Sharing, to stop that.")
                        .font(Typography.font(14, weight: .regular))
                        .foregroundStyle(EColor.onSurface)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 10) {
                        PrimaryButton(title: "Open Screen Time settings", systemIcon: "hourglass", action: onOpenSettings)
                        Button("Remind me later", action: onDismiss)
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Spacer()
            }
        }
    }
}

// MARK: - Trial-exhausted popup (Mia's "Evlin Plan" prompt)

// The plan status itself lives only in Settings > Parent Profile (and the
// Settings root's upsell row) — one place for an account-wide setting,
// not repeated per child. This is a different thing: a one-time nudge that
// pops up the moment a trial-exhausted child's profile opens (Mia, in the
// mock data), same floating-card-over-scrim language as UnlockConfirmCard
// elsewhere in this file, instead of a flat card sitting in the scroll
// content that's easy to miss by not scrolling down to it.
private struct TrialExhaustedPopupCard: View {
    var childName: String
    var isUpgrading: Bool
    var onUpgrade: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .center, spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(EColor.primaryContainer)
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "sparkles").font(.system(size: 19, weight: .semibold)).foregroundStyle(EColor.primary))

                    Text("You've used your free trial")
                        .font(Typography.font(18, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                        .multilineTextAlignment(.center)
                    Text("Upgrade to Evlin Plus to keep managing \(childName)'s screen time, tasks, and rules.")
                        .font(Typography.font(13, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if isUpgrading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Upgrading…").font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity).frame(height: 52)
                    } else {
                        PrimaryButton(title: "Upgrade to Evlin Plus", systemIcon: "sparkles", action: onUpgrade)
                        Button("Not now", action: onDismiss)
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

// MARK: - Grant extra time (tasks already done, allowance used up)

// Once chores are done, unlocking isn't a "should they" question
// anymore, it's a "how much" one — so this asks for an amount instead of a
// bare confirm, and warns proportionally to how much is picked, rather than
// scaring the parent off of any top-up at all.
private struct GrantExtraTimeSheet: View {
    let childName: String
    let dailyLimitMin: Int
    let usageTodayMin: Int
    let onGrant: (Int) -> Void
    let onCancel: () -> Void

    // The two-hour mark is the general guideline for kids' daily recreational
    // screen time — the warning below is pinned to *that*, not to the size
    // of the top-up. 15 more minutes reads very differently for a kid who's
    // had 20 minutes today than one who's already had 2 hours; a flat set of
    // fixed options with a warning keyed only to the increment couldn't tell
    // those apart.
    private let twoHours = 120
    private let presetOptions = [15, 30, 60]
    // Every 15 minutes from 15m up to 4h — a horizontal scroll-to-pick ruler
    // (the 4th "Custom" slot) rather than a text field, so any in-between
    // amount is still just a scroll away instead of typing digits.
    private let customOptions: [Int] = Array(stride(from: 15, through: 240, by: 15))
    @State private var selected = 15
    @State private var isCustomActive = false
    @State private var customScrollID: Int? = 15

    private var projectedTotal: Int { usageTodayMin + selected }

    private var alreadyOverTwoHours: Bool { usageTodayMin >= twoHours }

    private var warning: (color: Color, icon: String, text: String) {
        let total = formatMinutes(projectedTotal)
        switch projectedTotal {
        case ..<twoHours:
            return (Color(hex: "25924A"), "checkmark.circle.fill",
                    "\(childName) would be at \(total) of total screen time today — still under the general 2-hour guideline.")
        case twoHours..<180:
            return (Color(hex: "B26A00"), "exclamationmark.triangle.fill",
                    "\(childName) would be at \(total) today — over the general 2-hour guideline for kids' recreational screen time. Consider keeping this short.")
        default:
            return (EColor.danger, "exclamationmark.octagon.fill",
                    "\(childName) would be at \(total) today — well past 2 hours. Extended screen time like this is linked to worse sleep, mood, and attention.")
        }
    }

    // Horizontal scroll-to-pick strip for the "Custom" slot — snaps to
    // 15-minute increments as the parent scrolls sideways through
    // customOptions, rather than a text field or a vertical wheel. White,
    // not the app's usual light-gray field fill, to match the crisp white
    // boxes used elsewhere for a deliberate choice (e.g. UnlockConfirmCard's
    // buttons) rather than reading as just another muted form field.
    private var customRuler: some View {
        let itemWidth: CGFloat = 68
        let itemHeight: CGFloat = 56
        // Each item gets the box's full height explicitly, rather than
        // relying on the horizontal ScrollView to center shorter content
        // on its cross axis — that centering isn't reliable, and without
        // it the text pins to the top of the 56pt box, leaving the rest
        // looking like a broken half-empty sliver instead of a clean
        // white card.
        return GeometryReader { geo in
            let sideInset = max(0, (geo.size.width - itemWidth) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(customOptions, id: \.self) { minutes in
                        Text(formatMinutes(minutes))
                            .font(Typography.font(minutes == selected ? 17 : 14, weight: minutes == selected ? .heavy : .semibold))
                            .foregroundStyle(minutes == selected ? EColor.primary : EColor.onSurfaceVariant)
                            .frame(width: itemWidth, height: itemHeight)
                            .id(minutes)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $customScrollID)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .overlay {
                Capsule()
                    .fill(EColor.primary.opacity(0.1))
                    .frame(width: itemWidth - 10, height: 40)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: itemHeight)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
        .onChange(of: customScrollID) { _, newValue in
            if let newValue { selected = newValue }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Give \(childName) more time?")
                        .font(Typography.font(18, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alreadyOverTwoHours ? "exclamationmark.octagon.fill" : "clock.fill")
                            .foregroundStyle(alreadyOverTwoHours ? EColor.danger : EColor.onSurfaceVariant)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatMinutes(usageTodayMin)) used today")
                                .font(Typography.font(15, weight: .heavy))
                                .foregroundStyle(alreadyOverTwoHours ? EColor.danger : EColor.onSurface)
                            if alreadyOverTwoHours {
                                Text("Already over the 2-hour guideline, before any extra time.")
                                    .font(Typography.font(12, weight: .medium))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                    }
                    .padding(14)
                    .background(EColor.surfaceContainerLowest)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("HOW MUCH EXTRA TIME?").font(Typography.font(11, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant)
                        HStack(spacing: 8) {
                            ForEach(presetOptions, id: \.self) { minutes in
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { selected = minutes; isCustomActive = false }
                                } label: {
                                    Text(formatMinutes(minutes))
                                        .font(Typography.font(14, weight: .bold))
                                        .foregroundStyle(!isCustomActive && selected == minutes ? .white : EColor.onSurface)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(!isCustomActive && selected == minutes ? EColor.primary : EColor.surfaceContainerLowest)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().strokeBorder(EColor.outlineVariant, lineWidth: !isCustomActive && selected == minutes ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                customScrollID = selected
                                withAnimation(.easeOut(duration: 0.15)) { isCustomActive = true }
                            } label: {
                                Text("Custom")
                                    .font(Typography.font(14, weight: .bold))
                                    .foregroundStyle(isCustomActive ? .white : EColor.onSurface)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(isCustomActive ? EColor.primary : EColor.surfaceContainerLowest)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().strokeBorder(EColor.outlineVariant, lineWidth: isCustomActive ? 0 : 1))
                            }
                            .buttonStyle(.plain)
                        }

                        // Its own labeled slot, not just tucked under the
                        // chip row — a value picker reads as a bigger
                        // decision than a preset tap, so it gets a beat of
                        // separation instead of sitting flush against the
                        // chips.
                        if isCustomActive {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SCROLL TO SET").font(Typography.font(10, weight: .bold)).tracking(0.6).foregroundStyle(EColor.onSurfaceVariant)
                                customRuler
                            }
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: isCustomActive)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: warning.icon).foregroundStyle(warning.color)
                        Text(warning.text).font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurface)
                    }
                    .padding(14)
                    .background(warning.color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: selected)

                    VStack(spacing: 10) {
                        PrimaryButton(title: "Give \(formatMinutes(selected)) more") { onGrant(selected) }
                        cardButton("Cancel", tint: EColor.onSurfaceVariant, action: onCancel)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Spacer()
            }
        }
    }

    // Matches UnlockConfirmCard's own (private, so not shared directly) —
    // same white bordered pill for the secondary action on both cards.
    private func cardButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.font(15, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EColor.outlineVariant, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Parent-approval verifying overlay

// The actual "passwordless authentication" beat: tapping Approve on
// approvalBanner doesn't flip the status immediately — it shows this for a
// moment first, mirroring the timed-transition idiom this app already uses
// for other mocked async steps (e.g. ParentWaitingForKidStep). There's no
// real biometric check here (no LocalAuthentication call) — being the
// parent who's physically inside this child's profile *is* the factor.
private struct ParentApprovalVerifyingOverlay: View {
    var onDone: () -> Void

    @State private var verified = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()

            VStack(spacing: 14) {
                SecurityLottieView(size: 96)
                Text(verified ? "Approved" : "Verifying it's you…")
                    .font(Typography.font(16, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                if verified {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Brand.greenDeep)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(28)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
            .padding(.horizontal, 44)
        }
        .animation(.easeOut(duration: 0.2), value: verified)
        .transition(.opacity)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            verified = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            onDone()
        }
    }
}

// MARK: - Unlock confirm card

// A floating card over a dimmed backdrop, matching the app's other
// confirm-card visual language — used in place of a plain native .alert for
// the "master" lock/unlock button's confirm-before-unlocking step. Both
// buttons are white (bordered) rather than solid-color pills, so neither
// reads as more "default" than the other — this is a decision worth a
// second's pause, not a quick reflex tap.
private struct UnlockConfirmCard: View {
    var childName: String
    // Raw count, not pre-formatted text — lets this card pick its own
    // severity color the same way GrantExtraTimeSheet's warning box escalates
    // with the selected amount, instead of a flat gray box regardless of how
    // much is still left undone.
    var remaining: Int
    var onUnlock: () -> Void
    var onCancel: () -> Void

    private var warning: (color: Color, icon: String, text: String) {
        guard remaining > 0 else {
            return (Color(hex: "25924A"), "checkmark.circle.fill",
                    "Sticking to the usual schedule keeps limits predictable for \(childName).")
        }
        let task = remaining == 1 ? "task" : "tasks"
        let text = "\(childName) has \(remaining) \(task) left today. Finishing them first helps screen time feel earned."
        // One task left reads as "almost done" (amber); several still open is
        // the more serious "unlocking before real progress" case (red) —
        // same two-tier escalation GrantExtraTimeSheet uses for its amount.
        return remaining == 1
            ? (Color(hex: "B26A00"), "exclamationmark.triangle.fill", text)
            : (EColor.danger, "exclamationmark.octagon.fill", text)
    }

    var body: some View {
        ZStack {
            // Its own plain-opacity transition, separate from the card's
            // below — the two used to share one .transition(scale+opacity)
            // on this whole ZStack, which scaled the full-bleed scrim down
            // right along with the card. A scrim that shrinks reveals real
            // background at its edges mid-animation, reading as the
            // background itself glitching/sliding rather than a clean
            // spotlight-style dim.
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(EColor.danger)
                        Text("Unlock \(childName)'s devices?")
                            .font(Typography.font(18, weight: .heavy))
                            .foregroundStyle(EColor.onSurface)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: warning.icon).foregroundStyle(warning.color)
                        Text(warning.text)
                            .font(Typography.font(14, weight: .regular))
                            .foregroundStyle(EColor.onSurface)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(warning.color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(spacing: 10) {
                        cardButton("Unlock now", tint: EColor.danger, action: onUnlock)
                        cardButton("Cancel", tint: EColor.onSurfaceVariant, action: onCancel)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Spacer()
            }
        }
    }

    private func cardButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.font(15, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EColor.outlineVariant, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Task

private struct AddTaskSheet: View {
    @ObservedObject var child: Child
    var onCreate: (ChildTask) -> Void
    var onCancel: () -> Void

    @State private var title = ""
    @State private var category = "Chore"
    @State private var description = ""
    @State private var repeatDays: Set<String> = []
    // AddTaskFormFields is shared with Calendar's own Add Task, which
    // isn't scoped to one child and needs a real personId binding — this
    // sheet is already scoped via `child`, so it's seeded once and never
    // surfaced (fixedChild hides the For picker that would otherwise show it).
    @State private var personId: String

    // The day the task is due: the one Home's Today / Tomorrow tab is
    // showing. No date picker here; the tab already says which day. A
    // deadline (More options) only adds a time on that day.
    var day: Date
    @State private var hasDeadline = false
    @State private var deadline = Date()

    private var dueMoment: Date { TaskDeadlineField.moment(deadline, on: day) }

    init(child: Child, day: Date, onCreate: @escaping (ChildTask) -> Void, onCancel: @escaping () -> Void) {
        self.child = child
        self.day = day
        self.onCreate = onCreate
        self.onCancel = onCancel
        _personId = State(initialValue: child.id)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        AddTaskFormFields(
            title: "New task", saveLabel: "Create task", fixedChild: child,
            taskTitle: $title, personId: $personId, whatToDo: $description, repeatDays: $repeatDays,
            hasDeadline: $hasDeadline, deadline: $deadline, day: day,
            canSave: canSave, onCancel: onCancel, onSave: {
                let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
                onCreate(ChildTask(
                    id: UUID().uuidString, occurrenceId: nil, title: title, state: .pending, category: category,
                    description: description, note: nil, submittedAt: nil,
                    dueLabel: hasDeadline ? ChildRule.fmtClock(dueMoment) : nil,
                    dueDate: hasDeadline ? dueMoment : day, photoCount: 0,
                    repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
                ))
            }
        )
    }
}

// MARK: - Home design pieces

/// How strongly a card on a child's page is dimming the screen; Home dims
/// its header by the same amount. With several pages (a swipeable pager),
/// the strongest wins: only the page on screen can be showing a card.
struct HomeScrimKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

// The Home design's own palette, where the app's tokens don't have an
// equivalent: the soft grey review strip, the amber review accent and the
// muted label grey.
enum HomeStyle {
    static let green = Color(hex: "1FA971")
    static let red = Color(hex: "E0483C")
    static let amber = Color(hex: "E8962C")
    static let amberSoft = Color(hex: "FDF0DF")
    static let sunk = Color(hex: "F6F7F9")
    static let line = Color(hex: "EDEFF2")
    static let muted = Color(hex: "8894A6")
}

// The status header's colours: iOS's own system green and red for open and
// locked, and the system label greys.
enum StatusCardStyle {
    static let green = Color(hex: "34C759")
    static let red = Color(hex: "FF3B30")
    static let secondaryLabel = Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.6)
    static let tertiaryLabel = Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.3)
    static let separator = Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.15)
}

// A row that dims while pressed, like a system list cell.
private struct PressedOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// The status header: the state in words on the left, and a track from there
// to the lock button that wraps around it. The track fills with today's
// tasks: half the line per task done, the whole line one short of done, and
// the ring with the last, when the button turns green to unlock. While the
// phone is open it shows the time left instead.
private struct StatusPathHeader: View {
    enum Phase: Equatable {
        /// Locked for tasks: some of today's still to do.
        case tasks(done: Int, total: Int)
        /// Tasks are waiting for parent review; the button approves them.
        case ready(timeLeft: String)
        /// Open, with this much time left.
        case open(timeLeft: String, fraction: Double)
        /// Locked while some of today's earned time remains.
        case paused(timeLeft: String)
        /// The day's screen time is used up.
        case timeUp
        case downtime(until: String)
    }

    var phase: Phase
    var childName: String
    var action: () -> Void

    // Counts taps, so the haptic answers the parent's own tap and never a
    // change that arrived by sync.
    @State private var taps = 0

    private let buttonSize: CGFloat = 52
    private let ringRadius: CGFloat = 30
    private let lineWidth: CGFloat = 4.5
    private static let trackGrey = Color(hex: "E5E5EA")

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width - ringRadius - lineWidth / 2, y: ringRadius + lineWidth / 2)
            let track = StatusTrack(center: center, radius: ringRadius, startX: lineWidth / 2)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            ZStack(alignment: .topLeading) {
                if !isDowntime {
                    track.stroke(Self.trackGrey, style: style)
                    track.trim(from: 0, to: filled(lineLength: center.x - lineWidth / 2))
                        .stroke(fillColor, style: style)
                }
                statusText
                    .padding(.top, 14)
                    .frame(maxWidth: center.x - ringRadius - 12, alignment: .leading)
                lockButton
                    .position(center)
            }
        }
        .frame(height: ringRadius * 2 + lineWidth)
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: phase)
    }

    private var isDowntime: Bool { if case .downtime = phase { return true } else { return false } }

    // How much of the track is filled, as a share of its whole length.
    private func filled(lineLength: CGFloat) -> CGFloat {
        let ring = 2 * .pi * ringRadius
        let whole = lineLength + ring
        switch phase {
        case let .tasks(done, total):
            guard total > 1 else { return done >= 1 ? lineLength / whole : 0 }
            return lineLength * CGFloat(min(done, total - 1)) / CGFloat(total - 1) / whole
        case .ready(_): return 1
        case let .open(_, fraction): return CGFloat(max(0, min(1, fraction)))
        case .paused(_), .timeUp, .downtime: return 0
        }
    }

    private var fillColor: Color { StatusCardStyle.green }

    @ViewBuilder private var statusText: some View {
        switch phase {
        case let .tasks(done, total):
            numberLine("\(done)", "of \(total) done", numberColor: done > 0 ? StatusCardStyle.green : EColor.onSurface)
        case let .ready(timeLeft):
            numberLine(timeLeft, "left", numberColor: StatusCardStyle.green)
        case let .open(timeLeft, _):
            numberLine(timeLeft, "left", numberColor: StatusCardStyle.green)
        case let .paused(timeLeft):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeLeft)
                    .font(Typography.font(28, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.secondaryLabel)
                    .contentTransition(.numericText())
                Text("left")
                    .font(Typography.font(16, weight: .regular))
                    .foregroundStyle(StatusCardStyle.secondaryLabel)
                Circle()
                    .fill(StatusCardStyle.tertiaryLabel)
                    .frame(width: 3, height: 3)
                    .padding(.horizontal, 2)
                Text("Locked")
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.secondaryLabel)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
        case .timeUp:
            // Out of time: the time left, nothing, greyed out.
            numberLine("0m", nil, numberColor: StatusCardStyle.secondaryLabel)
        case let .downtime(until):
            numberLine("Until \(until)", nil, numberColor: downtimeIndigo)
        }
    }

    private func numberLine(_ number: String, _ suffix: String?, numberColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number)
                .font(Typography.font(28, weight: .semibold))
                .foregroundStyle(numberColor)
                .contentTransition(.numericText())
            if let suffix {
                Text(suffix)
                    .font(Typography.font(16, weight: .regular))
                    .foregroundStyle(StatusCardStyle.secondaryLabel)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private var lockButton: some View {
        Button { taps += 1; action() } label: {
            Group {
                if isOpen {
                    SemiUnlockGlyph()
                        .foregroundStyle(iconColor)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(iconColor)
                        // Calm: a quiet cross-fade between icons, no bounce.
                        .contentTransition(.opacity)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .background {
                // Filled green over a green ring, the two only touched
                // edge to edge and a hairline of white showed between
                // them. Filled, the disc grows to cover the whole ring.
                Circle().fill(buttonFill)
                    .frame(width: discSize, height: discSize)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDowntime)
        .accessibilityLabel(isOpen ? "Lock \(childName)'s phone"
                    : (isReady ? "Approve everything \(childName) sent in" : "Unlock \(childName)'s phone"))
        .accessibilityValue(isOpen ? "Open" : (isDowntime ? "Downtime" : "Locked"))
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
    }

    private var isOpen: Bool { if case .open = phase { return true } else { return false } }
    private var isReady: Bool { if case .ready = phase { return true } else { return false } }

    private var discSize: CGFloat {
        if case .ready(_) = phase { return (ringRadius + lineWidth / 2) * 2 }
        return buttonSize
    }

    private var icon: String {
        switch phase {
        case .ready(_): return "checkmark"
        case .downtime: return "moon.fill"
        default: return "lock.fill"
        }
    }

    private var iconColor: Color {
        switch phase {
        case .tasks, .paused(_), .timeUp: return StatusCardStyle.red
        case .ready(_), .downtime: return .white
        case .open: return StatusCardStyle.green
        }
    }

    private var buttonFill: Color {
        switch phase {
        case .ready(_): return StatusCardStyle.green
        case .downtime: return downtimeIndigo
        default: return Color.white
        }
    }
}

// The track: a straight line from the left to the bottom of the ring around
// the lock button, then once round the ring, so the fill runs along the line
// and on into the circle without a break.
private struct StatusTrack: Shape {
    var center: CGPoint
    var radius: CGFloat
    var startX: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bottom = CGPoint(x: center.x, y: center.y + radius)
        path.move(to: CGPoint(x: startX, y: bottom.y))
        path.addLine(to: bottom)
        // Up the right side first, carrying on from the line's direction.
        path.addArc(center: center, radius: radius, startAngle: .degrees(90), endAngle: .degrees(-270), clockwise: true)
        return path
    }
}

// One task row: a thin ring, the title, and a calm "day, time" line under
// it. The ring says the state at a glance: the child's colour while to do,
// red with "!" when late, amber when it's waiting on the parent,
// filled with a tick when done. Dashed for tomorrow, which can't be opened
// yet. Hairlines between rows come from the list (taskList), not the row.
private struct HomeTaskRow: View {
    var task: ChildTask
    var color: Color
    var isTomorrow: Bool
    /// Ticked a moment ago: drawn done while the row waits to move.
    var justChecked: Bool = false
    /// Tapping the ring checks the task off, or un-checks it. Nil: the
    /// ring is just a picture (tomorrow).
    var onRingTap: (() -> Void)? = nil

    private var isDone: Bool { justChecked || task.state == .done || task.state == .bypassed }
    private var waitingOnParent: Bool { task.state == .review || task.state == .bypass }

    private var ringColor: Color {
        if task.state == .overdue { return HomeStyle.red }
        if waitingOnParent { return HomeStyle.amber }
        return color
    }

    // The line under the name, only when it adds something: the due time,
    // "Overdue", or a skip. The Today/Tomorrow tab already says which day,
    // and the section headings say done or to do, so a task with no time
    // has no second line.
    private var detail: String? {
        switch task.state {
        case .done: return nil
        case .bypassed: return "Skipped"
        case .bypass: return "Asked to skip"
        case .pending, .overdue, .review:
            if let label = task.dueLabel, !label.isEmpty { return label }
            return task.state == .overdue ? "Overdue" : nil
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if isDone {
                    Circle().fill(color)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    Circle()
                        .strokeBorder(ringColor.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: isTomorrow ? [4, 3] : []))
                    if task.state == .overdue {
                        Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(ringColor)
                    }
                }
            }
            .frame(width: 40, height: 40)
            // A bigger target than the ring it draws, and a tap of its own:
            // it wins over the row's tap, which opens the task.
            .padding(6)
            .contentShape(Circle())
            .onTapGesture { onRingTap?() }
            .allowsHitTesting(onRingTap != nil)
            .accessibilityElement()
            .accessibilityLabel(isDone ? "Done" : "Not done")
            .accessibilityAddTraits(onRingTap == nil ? [] : .isButton)
            .accessibilityHint(onRingTap == nil ? "" : (isDone ? "Sends it back to the kid" : "Checks it off"))
            .padding(-6)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(Typography.font(16.5, weight: .bold))
                    .foregroundStyle(isDone ? HomeStyle.muted : EColor.onSurface)
                    .strikethrough(isDone, color: HomeStyle.muted)
                if let detail {
                    Text(detail)
                        .font(Typography.font(14.5, weight: .regular))
                        .foregroundStyle(task.state == .overdue ? HomeStyle.red : HomeStyle.muted)
                        .strikethrough(isDone, color: HomeStyle.muted)
                }
            }
            Spacer(minLength: 0)
            // Every row opens: today's to review, tomorrow's to edit.
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StatusCardStyle.tertiaryLabel)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A modern semi-unlocked padlock matching Apple's `lock.fill` in
/// proportions, weight, and continuous corner curvature, with the shackle
/// lifted slightly and cleanly unhooked on the right.
private struct SemiUnlockGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let bodyW: CGFloat = 16.5
            let bodyH: CGFloat = 12.2
            let bodyCorner: CGFloat = 3.3
            let strokeW: CGFloat = 2.7
            let shackleW: CGFloat = 8.8
            let r = shackleW / 2

            let centerX = size.width / 2
            let bodyY = size.height / 2 - bodyH / 2 + 3.6
            let bodyRect = CGRect(x: centerX - bodyW / 2, y: bodyY, width: bodyW, height: bodyH)

            // Solid body matching lock.fill
            ctx.fill(Path(roundedRect: bodyRect, cornerRadius: bodyCorner, style: .continuous), with: .foreground)

            // Shackle: lifted slightly with right leg unhooked above the body
            let leftX = centerX - r
            let rightX = centerX + r
            let archTop = bodyRect.minY - 9.6

            var shackle = Path()
            // Anchored into the lock body
            shackle.move(to: CGPoint(x: leftX, y: bodyRect.minY + 2.5))
            shackle.addLine(to: CGPoint(x: leftX, y: archTop + r))
            shackle.addArc(center: CGPoint(x: centerX, y: archTop + r),
                           radius: r,
                           startAngle: .degrees(180),
                           endAngle: .degrees(0),
                           clockwise: false)
            // Unhooked, cleanly suspended above the body
            shackle.addLine(to: CGPoint(x: rightX, y: bodyRect.minY - 3.2))

            ctx.stroke(shackle, with: .foreground, style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 26)
    }
}
