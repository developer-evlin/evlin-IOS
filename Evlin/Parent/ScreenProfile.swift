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
    @State private var showAddTask = ["newtask", "writetask"].contains(DemoMode.parentOpen ?? "")
    // A task on the Tomorrow tab, open in the edit form. Tomorrow's tasks
    // have nothing to review yet, so tapping one edits it instead.
    @State private var editingTomorrowTask: ChildTask?
    @State private var showUnlockConfirm = false
    @State private var showGrantTimeSheet = false
    /// The quick "Mia's phone is locked / unlocked" note after a change.
    // Drives the brief "verifying it's you" beat between tapping Approve in
    // approvalBanner and actually flipping child.parentApprovalStatus — see
    // ParentApprovalVerifyingOverlay below.
    @State private var showApprovalVerify = false
    @ObservedObject private var billing = BillingState.shared
    // The free trial's end, as a slim card under the status (never a
    // pop-up): put away for this visit with its x, or opens the plan page.
    @State private var trialCardDismissed = false
    @State private var showPlan = false
    @State private var showProtectionSetupPopup = false
    // Today / Tomorrow / This week / Goals tabs over the list.
    @State private var lane: HomeLane = DemoMode.homeLane.flatMap(HomeLane.init(rawValue:)) ?? (DemoMode.parentOpen == "habittour" ? .goals : .today)
    // The page the lanes' pager is on.
    @State private var pagerLane: HomeLane? = DemoMode.homeLane.flatMap(HomeLane.init(rawValue:)) ?? (DemoMode.parentOpen == "habittour" ? .goals : .today)
    // The day picked in This week's strip.
    @State private var weekDay = Calendar.current.startOfDay(for: Date())
    // This week (0) or next week (1) in the week lane.
    @State private var weekOffset = 0
    // The Goals lane: a new goal (the +), or one open.
    @State private var newGoal = ["newgoal", "goalbuild", "goalown", "goalprize", "goalpictures"].contains(DemoMode.parentOpen ?? "")
    @State private var openGoal: Goal?
    /// Demo screenshots: a goal's edit form straight away.
    @State private var editGoalForDemo: Goal?
    @State private var viewingGoal: Goal?
    @ObservedObject private var goalStore = GoalStore.shared
    /// "Tap to approve" under a waiting habit, until the parent first answers one.
    @AppStorage(GoalStore.approveHintKey) private var approveHint = true
    /// The habit the first habit's tour is waiting to show on, and its ring.
    @AppStorage(HabitTour.pendingKey) private var habitTourGoal = ""
    @State private var ringFrames: [String: CGRect] = [:]
    /// New task opened while the child had no tasks.
    @State private var addingFirstTask = false
    /// Where "Add Mia's first task" and the floating + are on screen, for
    /// the dotted arrow drawn from one to the other.
    @State fileprivate var firstTaskWords: CGRect?
    @State fileprivate var plusFrame: CGRect?
    @AppStorage(StatusPathHeader.lookAtDeviceKey) private var lookAtDevice = false
    @Namespace private var dayTabs
    // A success tap as a new task is saved.
    @State private var addedTick = 0
    // Rings ticked a moment ago, drawn done while their rows wait to move.
    @State private var justChecked: Set<String> = []
    @State private var changingGroup: Set<String> = []
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

    /// How the unlock card comes and goes: a smooth rise, no bounce.
    static let cardSpring = Animation.spring(duration: 0.38, bounce: 0)

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
                if EvlinPlan.offered && child.trialExhausted && !billing.isPlus && !trialCardDismissed {
                    UpgradeCard(title: "Your free trial has ended",
                                subtitle: "Keep repeating tasks, downtime and bedtime with Pro",
                                onUpgrade: { showPlan = true },
                                onDismiss: { withAnimation(.easeOut(duration: 0.2)) { trialCardDismissed = true } })
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                dayTabBar
                    .padding(.top, 28)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .parentContentColumn(adaptive.contentMaxWidth)

            // The lanes side by side in the system's own paging scroll
            // view: iOS tells a sideways swipe from a scroll itself, with
            // its own physics, so the two never fight.
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(HomeLane.allCases, id: \.self) { page in
                            ScrollView {
                                laneContent(page)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 24)
                                    .parentContentColumn(adaptive.contentMaxWidth)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(page)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $pagerLane)
            }
            .onChange(of: pagerLane) { _, l in
                guard let l, l != lane else { return }
                lane = l
            }
        }
        .modifier(AddAndGoals(screen: self))
        // The first task added: its lock is the moment to look at the
        // child's device (StatusPathHeader's line under the lock).
        .onChange(of: showAddTask) { _, open in
            if open && tasks.isEmpty { addingFirstTask = true }
        }
        .onChange(of: tasks.isEmpty) { _, empty in
            guard !empty, addingFirstTask else { return }
            addingFirstTask = false
            withAnimation(.spring(duration: 0.5, bounce: 0)) { lookAtDevice = true }
        }
        // Adding a task feels like approving one: success, as it's saved.
        .sensoryFeedback(.success, trigger: addedTick)
        // A selection tick, like a segmented control, when the day changes.
        .sensoryFeedback(.selection, trigger: lane)
        .sensoryFeedback(.success, trigger: checkedTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: landedTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: undoneTick)
        .background(EColor.surface)
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
                        withAnimation(Self.cardSpring) { showUnlockConfirm = false }
                    },
                    onCancel: { withAnimation(Self.cardSpring) { showUnlockConfirm = false } }
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
                        // Shown at once, like every other change: the new
                        // total from the phone's own count, not after the
                        // server answers (offline, that was never).
                        if let total = LocalStore.shared.mirrorTimeGrant(childId: child.id, minutes: minutes) {
                            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                                child.timeLeft = formatMinutes(total)
                                child.timePct = total > 0 ? 100 : 0
                            }
                        }
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
            if child.needsProtectionSetup { withAnimation(.easeOut(duration: 0.2)) { showProtectionSetupPopup = true } }
        }
        .sheet(isPresented: $showPlan) {
            EvlinPlanSheet()
                .presentationDragIndicator(.visible)   // nothing to lose here: swipes away
        }
        .sheet(item: $editingTomorrowTask) { task in
            Group {
            EditTaskReviewSheet(
                task: task,
                onSave: { updated, scope in
                    TaskEdits.save(updated, original: task, scope: scope, day: task.dueDate ?? Date(),
                                   clearDueTime: task.dueLabel != nil && updated.dueLabel == nil)
                    editingTomorrowTask = nil
                },
                onDelete: { scope in
                    // The sheet slides away first, then the row leaves.
                    editingTomorrowTask = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + TaskEdits.sheetCloseDelay) {
                        withAnimation(.spring(duration: 0.35, bounce: 0)) {
                            TaskEdits.delete(task, scope: scope, day: task.dueDate ?? Date())
                        }
                    }
                },
                onCancel: { editingTomorrowTask = nil }
            )
            .presentationDetents([.large])
        }
            .presentationDragIndicator(.visible)   // swipes away; held when there are changes (FormShell)
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
                            dueDate: Self.dueDateString(day),
                            needsPhoto: created.needsPhoto
                        )
                    }
                }
            }, onCancel: { showAddTask = false })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents([.large])
            .presentationBackground(EColor.surface)
        }
            .presentationDragIndicator(.visible)   // swipes away; held when there are changes (FormShell)
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
            EColor.scrim
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
                .background(EColor.raised)
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
                .background(filled ? tint : EColor.card)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(filled ? .clear : EColor.outlineVariant, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // The backdrop opacity of whichever card is showing over this page (all
    // of them dim with black at these strengths), or 0 when none is.
    private var cardScrimOpacity: Double {
        if showApprovalVerify { return 0.36 }
        if showUnlockConfirm || showGrantTimeSheet || showProtectionSetupPopup
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
    // button and wraps around it. Screen time (limit, downtime, blocked
    // apps) is the third tab's, under the hourglass.
    private var statusCard: some View {
        VStack(spacing: 0) {
            StatusPathHeader(phase: statusPhase, childName: child.name, action: toggleLock,
                             addMore: { showAddTask = true })
                .padding(.bottom, 10)
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
                return child.timePct > 0 ? .paused(timeLeft: child.timeLeft, fraction: Double(child.timePct) / 100) : .timeUp
            }
            // Everything sent in: still the tasks' progress, not the time.
            // The time is earned by the approval, so it shows after it.
            if !waitingForReview.isEmpty { return .ready(done: finishedCount, waiting: waitingForReview.count, total: total) }
            return child.timePct > 0 ? .paused(timeLeft: child.timeLeft, fraction: Double(child.timePct) / 100) : .timeUp
        }
    }

    // The same decisions the old Lock/Unlock button made: locking is
    // immediate; unlocking with tasks left asks first; with tasks done and
    // the day's time used up, it asks how much more.
    private func toggleLock() {
        switch statusPhase {
        case .open:
            // A manual lock is a pause, not time spent: whatever was left
            // comes back as-is on unlock. It locks at once: "Did you warn
            // Mia?" asked first until 2026-11-13 (removed, the user's call).
            applyManualLock(locked: true)
        case .ready:
            approveAll()
        case .timeUp:
            withAnimation(.easeOut(duration: 0.2)) { showGrantTimeSheet = true }
        case .tasks:
            if leftToDo > 0 {
                withAnimation(Self.cardSpring) { showUnlockConfirm = true }
            } else {
                applyManualLock(locked: false)
            }
        case .paused:
            if leftToDo > 0 {
                withAnimation(Self.cardSpring) { showUnlockConfirm = true }
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
    

    // The floating +, the Goals lane's sheets and the lanes' VoiceOver
    // actions, kept out of body (long
    // enough already for the type checker).
    private struct AddAndGoals: ViewModifier {
        let screen: ScreenProfile

        func body(content: Content) -> some View {
            content
                // The + floats bottom right, over the list, and adds a task for
                // the lane's day. On Goals it adds a goal, from four goals up;
                // under that the next ring does. A safeAreaInset reserves its
                // space, so the last row never sits under it.
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button {
                            if screen.lane == .goals { screen.newGoal = true } else { screen.showAddTask = true }
                        } label: {
                            // A child with no tasks yet: a hand taps this +
                            // again and again, under "Add Mia's first task"
                            // (2026-11-12: it tapped a green pill on the page).
                            if screen.firstTaskHint {
                                TappingHand { pressed in plusFace(pressed: pressed) }
                            } else {
                                plusFace(pressed: false)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(screen.addLabel)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screen.plusFrame = $0 }
                        .opacity(screen.floatingPlusHidden ? 0 : 1)
                        .disabled(screen.floatingPlusHidden)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                }
                .sheet(isPresented: screen.$newGoal) {
                    NewGoalSheet(child: screen.child)
                }
                .sheet(item: screen.$editGoalForDemo) { goal in
                    NewGoalSheet(child: screen.child, editing: goal)
                }
                .sheet(item: screen.$openGoal) { goal in
                    GoalSheet(goalId: goal.id, childName: screen.child.name)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
                .task {
                    if DemoMode.parentOpen == "goalcard" {
                        screen.openGoal = GoalStore.shared.goals(for: screen.child.id).first { !$0.waitingToday.isEmpty && !$0.photoWaiting }
                    }
                    if DemoMode.parentOpen == "goaledit" || DemoMode.parentOpen == "goaltype" {
                        screen.editGoalForDemo = GoalStore.shared.goals(for: screen.child.id).first
                    }
                    if DemoMode.parentOpen == "goalidle" {
                        screen.openGoal = GoalStore.shared.goals(for: screen.child.id).first { $0.waitingToday.isEmpty }
                    }
                    if DemoMode.parentOpen == "storyreach" {
                        screen.viewingGoal = GoalStore.shared.goals(for: screen.child.id).first { !$0.reached && !$0.waitingToday.isEmpty }
                    }
                }
                .fullScreenCover(item: screen.$viewingGoal) { goal in
                    GoalStoryViewer(goalId: goal.id, childName: screen.child.name) { screen.viewingGoal = nil }
                }
                // The dotted arrow from "Add Mia's first task" to the +.
                .overlay {
                    if screen.firstTaskHint, let words = screen.firstTaskWords, let plus = screen.plusFrame {
                        GeometryReader { g in
                            let o = g.frame(in: .global).origin
                            FirstTaskArrow(
                                from: CGPoint(x: words.midX - o.x, y: words.maxY - o.y + 14),
                                to: CGPoint(x: plus.minX - o.x - 12, y: plus.midY - o.y))
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .accessibilityAction(named: "Show habits") { screen.showLane(.goals) }
                .accessibilityAction(named: "Show this week") { screen.showLane(.week) }
                .accessibilityAction(named: "Show tomorrow") { screen.showLane(.tomorrow) }
                .accessibilityAction(named: "Show today") { screen.showLane(.today) }
        }

        private func plusFace(pressed: Bool) -> some View {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(hex: "E9E4D8"))
                .frame(width: 56, height: 56)
                // Black with a warm cream + (the user's final call,
                // 2026-11-05, after green was tried twice).
                .background(EColor.inkFill)
                .clipShape(Circle())
                // A ring goes out from the + as the hand presses it.
                .background {
                    Circle()
                        .stroke(EColor.inkFill, lineWidth: 2)
                        .padding(pressed ? -2 : -12)
                        .opacity(pressed ? 0.5 : 0)
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(pressed ? 0.92 : 1)
                .brightness(pressed ? 0.06 : 0)
        }
    }

    // MARK: - Tasks (Today / Tomorrow / This week, flat rows) and Goals

    // The lanes spread across the width with even gaps: Today at the left
    // edge, in line with the list, Goals near the right with room kept for
    // its count of today's check-ins waiting. (The + floats bottom
    // right.)
    private var dayTabBar: some View {
        let checkIns = goalStore.goals(for: childId).filter { !$0.waitingToday.isEmpty }.count
        return HStack(alignment: .center, spacing: 0) {
            dayTab("Today", on: lane == .today) { showLane(.today) }
            Spacer(minLength: 12)
            dayTab("Tomorrow", on: lane == .tomorrow) { showLane(.tomorrow) }
            Spacer(minLength: 12)
            dayTab("This week", on: lane == .week) { showLane(.week) }
            Spacer(minLength: 12)
            dayTab("Habits", on: lane == .goals, badge: checkIns) { showLane(.goals) }
        }
        // The badge's room past "Habits".
        .padding(.trailing, 14)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    /// Today for a child with no tasks at all: the hand taps the floating +.
    fileprivate var firstTaskHint: Bool { lane == .today && tasks.isEmpty }

    private var floatingPlusHidden: Bool {
        lane == .goals && goalStore.goals(for: childId).count < 4
    }

    private var addLabel: String {
        switch lane {
        case .today: return "Add a task for today"
        case .tomorrow: return "Add a task for tomorrow"
        case .week: return "Add a task for \(shownWeekDay.formatted(.dateTime.weekday(.wide)))"
        case .goals: return "New habit"
        }
    }

    @ViewBuilder private func laneContent(_ page: HomeLane) -> some View {
        switch page {
        case .today: dayList(tomorrow: false)
        case .tomorrow: dayList(tomorrow: true)
        case .week: weekList
        case .goals: goalsList
        }
    }

    // A real week, always Monday to Sunday: this week, or the next.
    private var weekDays: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        guard let start = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let first = cal.date(byAdding: .day, value: 7 * weekOffset, to: start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    private func isPast(_ d: Date) -> Bool { d < Calendar.current.startOfDay(for: Date()) }

    // The day picked in the week; if it isn't in the week showing, or has
    // passed, the first day still to come.
    private var shownWeekDay: Date {
        let days = weekDays
        if days.contains(weekDay) && !isPast(weekDay) { return weekDay }
        return days.first { !isPast($0) } ?? weekDay
    }

    // This week works like Tomorrow, for any day of the week: pick the day,
    // see its list (repeating tasks included, as they'll fall), and the +
    // adds to it. Days gone by are faded and can't be picked; the arrow
    // goes to next week.
    private var weekList: some View {
        let day = shownWeekDay
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let tasks = plannedTasks(childId: childId, on: day)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                // The tab already says "This week": just the dates here.
                Text(weekRange)
                    .font(Typography.font(15, weight: .bold))
                    .foregroundStyle(EColor.onSurface)
                    .contentTransition(.numericText())
                Spacer()
                weekArrow("chevron.left", enabled: weekOffset > 0, label: "This week") { weekOffset = 0 }
                weekArrow("chevron.right", enabled: weekOffset == 0, label: "Next week") { weekOffset = 1 }
            }
            .padding(.top, 10)
            HStack(spacing: 4) {
                ForEach(weekDays, id: \.self) { d in
                    let on = d == day
                    let past = isPast(d)
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { weekDay = d }
                    } label: {
                        VStack(spacing: 2) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated)))
                                .font(Typography.font(12.5, weight: .semibold))
                                .foregroundStyle(on ? HomeStyle.dayPickedText : HomeStyle.muted)
                            Text(d.formatted(.dateTime.day()))
                                .font(Typography.font(17, weight: .bold))
                                .foregroundStyle(on ? HomeStyle.dayPickedText : EColor.onSurface)
                                .monospacedDigit()
                            // A dot under today.
                            Circle().fill(on ? HomeStyle.dayPickedText : EColor.onSurface)
                                .frame(width: 4, height: 4)
                                .opacity(cal.isDateInToday(d) ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? HomeStyle.dayPicked : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(past ? 0.35 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(past)
                    .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).month().day()))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .sensoryFeedback(.selection, trigger: weekDay)
            .sensoryFeedback(.selection, trigger: weekOffset)

            if tasks.isEmpty {
                emptyLine(isToday ? "Nothing left for today." : "Nothing planned for \(day.formatted(.dateTime.weekday(.wide))) yet.")
            } else {
                // Today's rows work as on Today; any other day's open to edit.
                taskList([("week", nil, tasks)], isTomorrow: !isToday)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Nov 3 – 9".
    private var weekRange: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func weekArrow(_ icon: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { action() } } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(EColor.onSurface)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // The child's running goals as rings, two across as in Streaks: the name
    // and how far in short grey words under each. A goal with a check-in from
    // today waiting opens it to approve; any other opens the goal, to edit it,
    // finish it or delete it. Those waiting come first, their number pulsing
    // slightly (GoalRing), with no words. There's no limit: more rows of two
    // scroll with the page. Under four goals, Add habit takes the next place
    // as a ring; from four up it's Home's floating +.
    @ViewBuilder private var goalsList: some View {
        let running = goalStore.goals(for: childId)
        // In the order they were made: a ring approved by a tap stays where
        // it is, under the finger (waiting ones first moved it, 2026-11-08).
        let goals = running
        VStack(alignment: .leading, spacing: 0) {
            if goals.isEmpty {
                GoalsEmptyStart { newGoal = true }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2), spacing: 24) {
                    ForEach(goals) { goal in
                      VStack(spacing: 10) {
                        Button {
                            // The half card: with a check-in waiting, just
                            // Approve (no Redo; a parent who isn't happy tells
                            // the child). Otherwise Edit habit (2026-11-08).
                            openGoal = goal
                        } label: {
                            VStack(spacing: 12) {
                                GoalRing(goal: goal, size: GoalRingStyle.homeSize, line: GoalRingStyle.homeLine)
                                    // Where it is, for the first habit's tour.
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                                        ringFrames[goal.id] = f
                                    }
                                VStack(spacing: 2) {
                                    GoalRingStyle.name(goal.title)
                                    if !goal.waitingToday.isEmpty && approveHint {
                                        // Says what the badge means, in the badge's orange.
                                        Text("Tap to approve")
                                            .font(Typography.font(13, weight: .semibold))
                                            .foregroundStyle(GoalRingStyle.waitingBadge)
                                            .lineLimit(1)
                                    } else if let words = goalWords(goal) {
                                        Text(words)
                                            .font(Typography.font(13, weight: .medium))
                                            .foregroundStyle(HomeStyle.muted)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(goal.waitingToday.isEmpty ? goal.leftWords() : "\(goal.leftWords()), waiting for you to review")
                      }
                    }
                    if goals.count < 4 {
                        GoalAddCell { newGoal = true }
                    }
                }
                .padding(.top, 14)
                // Room under the last row, so the floating + never sits on a name.
                .padding(.bottom, goals.count >= 4 ? 84 : 0)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.3), value: goals.map(\.id))
        .animation(.snappy(duration: 0.3), value: goals.map(\.waitingToday.count))
        // The first habit's tour, on its ring while it's on screen and
        // nothing is over it.
        .onChange(of: habitTourTarget, initial: true) { _, ring in
            HabitTour.shared.show(ring, childName: child.name,
                                  habit: goals.first { $0.id == habitTourGoal }?.title ?? "")
        }
        .onDisappear { HabitTour.shared.show(nil, childName: child.name, habit: "") }
        .task {
            // Demo: the tour on Mia's Walk the dog.
            if DemoMode.parentOpen == "habittour" {
                UserDefaults.standard.set(false, forKey: HabitTour.doneKey)
                habitTourGoal = "goal-mia-dog"
            }
        }

    }

    /// Where the first habit's tour lights, while it can show: its habit's
    /// ring on screen, on the Habits lane, with no sheet over it.
    private var habitTourTarget: CGRect? {
        guard !habitTourGoal.isEmpty, pagerLane == .goals, !newGoal, openGoal == nil,
              let ring = ringFrames[habitTourGoal], ring.minX >= 0, ring.minY > 40,
              goalStore.goals(for: childId).contains(where: { $0.id == habitTourGoal }) else { return nil }
        return ring
    }

    // Only when it's out of the ordinary: the ring has the days left.
    private func goalWords(_ goal: Goal) -> String? {
        if goal.reached { return "Reached" }
        let todays = goal.entries.filter { Calendar.current.isDateInToday($0.at) }
        if !todays.isEmpty && todays.allSatisfy({ $0.status == .notApproved }) { return "Redo asked" }
        return nil
    }

    @ViewBuilder private func dayList(tomorrow: Bool) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let day = tomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today : today
        VStack(alignment: .leading, spacing: 0) {
            // Habit check-ins waiting for the parent: one card at the top of
            // Today (2026-11-05) that takes them to the Habits lane.
            if !tomorrow {
                let waitingGoals = goalStore.goals(for: childId).filter { !$0.waitingToday.isEmpty }
                if !waitingGoals.isEmpty {
                    HabitCheckInsCard(count: waitingGoals.reduce(0) { $0 + $1.waitingToday.count },
                                      childName: child.name) { showLane(.goals) }
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if tomorrow {
                if tomorrowsTasks.isEmpty {
                    emptyLine("Nothing planned for tomorrow yet.")
                } else {
                    taskList([("tomorrow", nil, tomorrowsTasks)], isTomorrow: true)
                }
            } else if tasks.isEmpty {
                // A child with no tasks yet (a new family): an invitation to
                // add the first, not "nothing left" (2026-11-08).
                FirstTaskStart(childName: child.name, onFrame: { firstTaskWords = $0 }) { showAddTask = true }
            } else if todaysTasks.isEmpty {
                emptyLine("Nothing left for today.")
            } else {
                // Grouped by what each needs, most urgent first: late, then
                // waiting on the parent, then still to do, then done. To do
                // and done have no heading: a gap sets them apart.
                let overdue = todaysTasks.filter { $0.state == .overdue }
                let waiting = todaysTasks.filter { $0.state == .review || $0.state == .bypass }
                taskList([
                    ("overdue", "Overdue", overdue),
                    ("waiting", "To review", waiting),
                    ("todo", nil, todaysTasks.filter { $0.state == .pending }),
                ], isTomorrow: false)
                let completed = todaysTasks.filter { $0.state == .done || $0.state == .bypassed }
                taskList([("done", nil, completed)], isTomorrow: false, gapAbove: completed.count < todaysTasks.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The ring as a checkbox. Ticking completes the task (as Approve does):
    // the ring fills at once, then a beat later the row moves to Completed,
    // so the tick is seen before the list changes. Un-ticking takes the
    // approval back: the task is as it was, waiting for review with what
    // the kid sent if they sent it in, else to do. (Sending it back with a
    // note is the review card's Redo.)
    private func toggleDone(_ task: ChildTask) {
        if task.state == .done || task.state == .bypassed {
            undoneTick += 1
            markChangingGroup(task.id)
            withAnimation(.spring(duration: 0.35, bounce: 0)) { TaskEdits.unapprove(task, childId: childId) }
            return
        }
        guard !justChecked.contains(task.id) else { return }
        checkedTick += 1
        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { _ = justChecked.insert(task.id) }
        // Held ticked for half a second so it's seen, then it leaves; a soft
        // tap as it lands in Completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            markChangingGroup(task.id)
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                TaskEdits.approve(task, childId: childId)
                justChecked.remove(task.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { landedTick += 1 }
        }
    }

    // Marks a row as moving group because of the parent's tap, for its
    // arrival (movedTransition), until it has arrived.
    private func markChangingGroup(_ id: String) {
        changingGroup.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { changingGroup.remove(id) }
    }

    // A tab tap: the pager slides to that lane.
    private func showLane(_ l: HomeLane) {
        guard l != lane else { return }
        withAnimation(.snappy(duration: 0.3)) {
            lane = l
            pagerLane = l
        }
    }

    // The list's lines: a section heading, the gap that opens a section
    // without one, or a task (with a hairline above it unless it opens its
    // section).
    private enum ListLine: Identifiable {
        case heading(String)
        case gap(String)
        case task(ChildTask, hairline: Bool, section: String)

        // A task's identity includes its group (to do, done...): changing
        // group is leaving one place and arriving in another, not a move.
        // The group, not what's above it: keying on that made every to-do
        // row vanish and come back whenever the group above came or went.
        var id: String {
            switch self {
            case .heading(let title): return "heading-\(title)"
            case .gap(let section): return "gap-\(section)"
            case .task(let task, _, let section): return "\(section)-\(task.id)"
            }
        }
    }

    // All the sections as one list: small bold headings or a gap, then rows with
    // hairlines between them (not above a section's first), inset to start
    // under the text. A task that changes section (ticked off, sent back)
    // fades out where it was while the rows below close up, then fades in
    // at its new place, as Things and Reminders do; it never travels across
    // the list over the other rows, which is what looked glitchy.
    private func taskList(_ sections: [(key: String, title: String?, tasks: [ChildTask])], isTomorrow: Bool, gapAbove: Bool = false) -> some View {
        var lines: [ListLine] = []
        for (key, title, tasks) in sections where !tasks.isEmpty {
            if let title {
                lines.append(.heading(title))
            } else if gapAbove || !lines.isEmpty {
                lines.append(.gap(key))
            }
            for (i, task) in tasks.enumerated() {
                lines.append(.task(task, hairline: i > 0, section: key))
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
                case .gap:
                    Color.clear
                        .frame(height: 20)
                        .accessibilityHidden(true)
                case .task(let task, let hairline, _):
                    HomeTaskRow(task: task, color: child.color, isTomorrow: isTomorrow,
                                justChecked: justChecked.contains(task.id),
                                onRingTap: isTomorrow ? nil : { toggleDone(task) })
                        .overlay(alignment: .top) {
                            Rectangle().fill(HomeStyle.line).frame(height: 1).padding(.leading, 62)
                                .opacity(hairline ? 1 : 0)
                        }
                        .onTapGesture {
                            if isTomorrow { editingTomorrowTask = task } else { onReview(task.id) }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(isTomorrow ? "Edits this task" : "Opens this task")
                        .transition(changingGroup.contains(task.id) ? Self.movedTransition : Self.lineTransition)
                }
            }
        }
        // Every change to the list moves the same way, a tick here or a
        // change a sync brought, so nothing jumps.
        .animation(.spring(duration: 0.35, bounce: 0), value: lines.map(\.id))
    }

    // A line arriving (a task just added, a heading) fades in once the rows
    // below have mostly made room: fading in at once drew it over the row
    // still sliding down out of its place. A line leaving goes at once:
    // the rows below slide up into its place, and fading it out instead
    // left it see-through on top of the row moving in.
    private static let lineTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
        removal: .identity
    )

    // A task the parent just ticked or unticked arrives in its new group
    // once the rows there have finished moving: shown at once, the heading
    // above slid down across it. (Only for those: a new task waiting out
    // the delay left a blank gap in the list.)
    private static let movedTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.3)),
        removal: .identity
    )

    private func dayTab(_ title: String, on: Bool, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(15, weight: .heavy))
                .foregroundStyle(on ? EColor.onSurface : HomeStyle.muted)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    if on {
                        Rectangle().fill(EColor.onSurface).frame(height: 2.5)
                            .matchedGeometryEffect(id: "dayTabUnderline", in: dayTabs)
                    }
                }
                // Up and to the right of the name, as on the avatars.
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(Typography.font(9.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(HomeStyle.waiting, in: Capsule())
                            .overlay(Capsule().strokeBorder(EColor.surface, lineWidth: 2))
                            .fixedSize()
                            .offset(x: 13, y: -8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(badge > 0 ? "\(badge) to approve" : "")
    }

    // The day the + adds to: whichever of Today / Tomorrow is showing, or
    // the day picked in This week.
    private var selectedDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        switch lane {
        case .today: return today
        case .tomorrow: return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        case .week: return shownWeekDay
        case .goals: return today
        }
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
            EColor.scrim
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
                .background(EColor.raised)
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
        .background(EColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
        .onChange(of: customScrollID) { _, newValue in
            if let newValue { selected = newValue }
        }
    }

    var body: some View {
        ZStack {
            EColor.scrim
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
                .background(EColor.raised)
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
                .background(EColor.card)
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
            .background(EColor.raised)
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
        let text = "\(childName) has \(remaining) \(task) left today. Skipping tasks may encourage unhealthy screen time habits."
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
            EColor.scrim
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

                    VStack(spacing: 6) {
                        // The answer as a filled button, the way out quieter.
                        Button(action: onUnlock) {
                            Text("Unlock now")
                                .font(Typography.font(15, weight: .bold))
                                .foregroundStyle(EColor.onDangerFill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(EColor.dangerFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(CardPressStyle())
                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(Typography.font(15, weight: .semibold))
                                .foregroundStyle(EColor.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(EColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                // Wider than the card's own 24pt corner radius — at 20pt
                // the margin was tighter than the curve itself, so each
                // rounded corner read as cramped against the screen's
                // square edge instead of floating clear of it.
                .padding(.horizontal, 28)
                // Rises a little as it fades in, from slightly smaller.
                .transition(.opacity.combined(with: .scale(scale: 0.92)).combined(with: .offset(y: 28)))
                Spacer()
            }
        }
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
    @State private var needsPhoto = false
    /// The name came from a Library chore (and wasn't changed after).
    @State private var fromLibrary: String?
    @State private var deadline = Date()
    /// What the tabs show. Opens on the last one the parent chose; only their
    /// own tap on a tab changes that, not an idea leading to the form.
    @State private var tab = DemoMode.parentOpen == "writetask" ? NewTaskTab.new : NewTaskTab.remembered
    /// Came to type their own, so the keyboard comes up. Not after an idea.
    @State private var writing = true
    /// "Let Mia pick": building a kid's pick instead of a task.

    private var dueMoment: Date { TaskDeadlineField.moment(deadline, on: day) }

    init(child: Child, day: Date, onCreate: @escaping (ChildTask) -> Void, onCancel: @escaping () -> Void) {
        self.child = child
        self.day = day
        self.onCreate = onCreate
        self.onCancel = onCancel
        _personId = State(initialValue: child.id)
    }

    /// "Let Mia choose" open on this category. Closed with every new sheet:
    /// + opens on New task or the Library, never back inside it.

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        sheetBody
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
                header
                if tab == .library {
                    TaskPicker(child: child, day: day, onPick: { t in
                        title = t.title
                        fromLibrary = t.title
                        // No What to do: a chore's name says enough (the
                        // user's call, 2026-11-05).
                        // Just the name, no repeat: a chore picked is for the
                        // day being shown (2026-11-15, the user's call: the
                        // chore's own repeat, Wed and Sat for the plants, left
                        // a parent picking it on a Monday wondering why it
                        // wasn't on today). Repeats is there to set by hand.
                        repeatDays = []
                        writing = false
                        withAnimation(.snappy(duration: 0.3)) { tab = .new }
                    })
                    .transition(.opacity)
                } else {
                    form.transition(.opacity)
                }
            }
            .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
            .presentationBackground(EColor.surface)
            .presentationDragIndicator(.visible)
            // A pull down from the top closes it, on either tab.
    }

    // The tabs in the middle, close at the right.
    private var header: some View {
        ZStack(alignment: .trailing) {
            NewTaskTabs(tab: tab) { chosen in
                UserDefaults.standard.set(chosen.rawValue, forKey: NewTaskTab.key)
                writing = true
                withAnimation(.snappy(duration: 0.3)) { tab = chosen }
            }
            .frame(maxWidth: .infinity)
            SheetCloseButton(label: "Cancel", action: onCancel)
        }
        // Full width with or without the tabs, so the x stays at the right.
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var form: some View {
        AddTaskFormFields(
            saveLabel: "Create task", fixedChild: child,
            taskTitle: $title, personId: $personId, whatToDo: $description, repeatDays: $repeatDays,
            hasDeadline: $hasDeadline, deadline: $deadline, needsPhoto: $needsPhoto, day: day,
            canSave: canSave, onCancel: onCancel, onSave: {
                let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
                // Next time New task opens where this one came from: the
                // Library for a chore picked there, New task for one typed.
                let picked = fromLibrary != nil && fromLibrary == title
                UserDefaults.standard.set((picked ? NewTaskTab.library : NewTaskTab.new).rawValue, forKey: NewTaskTab.key)
                onCreate(ChildTask(
                    id: UUID().uuidString, occurrenceId: nil, title: title, state: .pending, category: category,
                    description: description, note: nil, submittedAt: nil,
                    dueLabel: hasDeadline ? ChildRule.fmtClock(dueMoment) : nil,
                    dueDate: hasDeadline ? dueMoment : day, photoCount: 0,
                    repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ","),
                    needsPhoto: needsPhoto
                ))
            },
            focusName: writing
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
// equivalent: the soft grey review strip, the orange review accent and the
// muted label grey.
/// Home's lanes over the task list.
enum HomeLane: Int, CaseIterable, Hashable { case today, tomorrow, week, goals }


enum HomeStyle {
    // Calmer in Dark, so they don't glow on the dark page.
    static let green = Color(light: "1FA971", dark: "4CAF6A")
    static let red = Color(light: "E0483C", dark: "D9574D")
    /// Waiting on someone: to review, a check-in to answer.
    static let waiting = Color(light: "E8962C", dark: "C98A3E")
    // A step under the Alabaster page, as the habit rings' grey track
    // (2026-11-14: #ECE9E2, made for the cream, left the progress bar's
    // track invisible).
    static let sunk = Color(light: "E5E5EA", dark: "30353D")
    // Firmer on Alabaster, as `Neutral.line` (#E7E3DB before, 2026-11-14).
    static let line = Color(light: "E5E5EA", dark: "353A42")
    static let muted = Color(light: "64748B", dark: "9CA3AF")
    /// The picked day in This week: ink with white by day; in Dark a raised
    /// grey with soft white, not a glaring white block.
    static let dayPicked = Color(light: "15231A", dark: "414650")
    static let dayPickedText = Color(light: "FFFFFF", dark: "E4E4E6")
}

// The status header's colours: iOS's own system green and red for open and
// locked, and the system label greys.
enum StatusCardStyle {
    /// The done ticks', habit rings' and progress bar's green: by day the
    /// button green, as Add task (2026-11-16, the user's call: iOS's
    /// #34C759 read too bright on the cream; a warmer #56A659 was tried and
    /// rejected, 2026-11-05).
    static let green = Color(light: "2FA84F", dark: "4CAF6A")
    static let red = Color(light: "FF3B30", dark: "E5534B")
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.12) : UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.15) })
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
        /// Everything's sent in and waiting for the parent; the button
        /// approves it all. Shown as progress until then: no time yet.
        case ready(done: Int, waiting: Int, total: Int)
        /// Open, with this much time left.
        case open(timeLeft: String, fraction: Double)
        /// Locked while some of today's earned time remains.
        case paused(timeLeft: String, fraction: Double)
        /// The day's screen time is used up.
        case timeUp
        case downtime(until: String)
    }

    var phase: Phase
    var childName: String
    var action: () -> Void
    /// New task, from the first task's pop-up under the lock.
    var addMore: () -> Void = {}
    /// The shackle: 1 open. Approving everything opens the phone, and the
    /// lock arrives shut, then swings open (2026-11-08).
    @State private var shackle: CGFloat = 1

    // The master button: one big round button that locks and unlocks the
    // phone, centred at the top, with what a tap will do under it. Then the
    // day's progress on its own: words over a bar, the full width (a ring
    // around the button was tried, 2026-11-06).
    var body: some View {
        VStack(spacing: 0) {
            lockButton
            // What a tap does, only until the parent has done it once:
            // "Tap to unlock" while locked, "Tap to lock" while open, each
            // gone for good after its first tap (2026-11-07).
            if let hint {
                Text(hint)
                    .font(Typography.font(14, weight: .medium))
                    .foregroundStyle(StatusCardStyle.tertiaryLabel)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            // The day's progress on its own, the page's full width.
            StatusProgress(text: statusWords.text, suffix: statusWords.suffix, textColor: statusWords.color,
                           fraction: fraction, color: barColor,
                           stacked: isLocked, minutes: openMinutes)
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: phase)
        // The first lock's spotlight, over the whole app (ParentRootView):
        // shown while the lock is on screen here.
        .onChange(of: spotlight, initial: true) { _, now in
            FirstLockSpotlight.shared.show(now, childName: childName, addMore: addMore)
        }
        .onDisappear { FirstLockSpotlight.shared.show(nil, childName: childName, addMore: addMore) }
        // Approved into open: the green drains into the middle (in
        // HoldToActButton), the tick goes, the lock comes in shut and its
        // shackle springs open a beat later.
        .onChange(of: phase) { old, new in
            // The device opening (from locked) ends the first lock's pop-up;
            // not a passing state while the app starts up.
            switch (old, new) {
            case (.tasks, .open), (.tasks, .ready), (.paused, .open), (.timeUp, .open):
                if lookAtDevice { withAnimation(.spring(duration: 0.4, bounce: 0)) { lookAtDevice = false } }
            default: break
            }
            guard case .ready = old, case .open = new else { return }
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { shackle = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(duration: 0.5, bounce: 0.45)) { shackle = 1 }
            }
        }
    }

    // Green for what's earned and running; slate for time waiting behind
    // a lock.
    private var barColor: Color {
        switch phase {
        case .downtime: return downtimeIndigo
        case .paused, .timeUp: return Color(hex: "CBD5E1")
        default: return StatusCardStyle.green
        }
    }

    /// The time left as minutes while open, so it can count.
    private var openMinutes: Int? {
        guard case let .open(timeLeft, _) = phase else { return nil }
        var total = 0
        for part in timeLeft.split(separator: " ") {
            if part.hasSuffix("h"), let h = Int(part.dropLast()) { total += h * 60 }
            if part.hasSuffix("m"), let m = Int(part.dropLast()) { total += m }
        }
        return total
    }

    private var isLocked: Bool {
        if case .paused = phase { return true } else { return false }
    }

    private var isDowntime: Bool { if case .downtime = phase { return true } else { return false } }

    private var fraction: CGFloat { phase.fraction }
    private var statusWords: (text: String, suffix: String?, color: Color) { phase.words }

    // Tap to lock or unlock (HoldToActButton): a tap does what the old
    // switch did (`action`), so unlocking with tasks left still asks first
    // and running out of time still asks how much more. It acts at once;
    // the bar shows the change afterwards. Everything sent in, a tap
    // approves it all.
    private var lockButton: some View {
        lockButtonFace
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lockFrame = $0 }
    }

    /// Where the lock is on screen, for the spotlight.
    @State private var lockFrame: CGRect?
    /// The lock's frame while the first lock's spotlight should show.
    private var spotlight: CGRect? { showsLockedPopUp ? lockFrame : nil }

    private var lockButtonFace: some View {
        HoldToActButton(
            tint: restTint,
            fill: StatusCardStyle.green,
            enabled: !isDowntime,
            tapActs: isReady,
            accessibilityLabel: isOpen ? "Lock \(childName)'s phone"
                : (isReady ? "Approve everything \(childName) sent in"
                   : (isDowntime ? "\(childName)'s phone is in downtime" : "Unlock \(childName)'s phone")),
            size: Self.buttonSize,
            onComplete: tapped,
            icon: {
            switch phase {
            case .ready:
                ApproveCheck(fontSize: 44)
                    .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity),
                                            removal: .scale(scale: 0.3).combined(with: .opacity)))
            case .downtime:
                Image(systemName: "moon.fill")
                    .font(.system(size: 46, weight: .semibold))
            default:
                LockGlyph(open: isOpen ? shackle : 0)
                    .stroke(style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 52, height: 52)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            }
        )
    }

    private static let buttonSize: CGFloat = 148

    /// "Tap to lock", on until the parent has used it once. Locked there's
    /// no "Tap to unlock" (removed 2026-11-11, the user's call).
    @AppStorage("evlin.lockHint") private var lockHint = true
    /// Set when the first task is added: the child's device has just
    /// locked, so the parent is asked to go and see it (2026-11-11).
    @AppStorage(Self.lookAtDeviceKey) private var lookAtDevice = false
    static let lookAtDeviceKey = "evlin.lookAtDevice"

    private var hint: String? {
        switch phase {
        case .open: return lockHint ? "Tap to lock" : nil
        default: return nil
        }
    }

    /// Locked by the first task: a pop-up under the lock says so.
    private var showsLockedPopUp: Bool {
        switch phase {
        case .tasks, .paused, .timeUp: return lookAtDevice
        default: return false
        }
    }

    private func tapped() {
        switch phase {
        case .open: lockHint = false
        case .tasks, .paused, .timeUp: lookAtDevice = false
        default: break
        }
        action()
    }

    private var isOpen: Bool { if case .open = phase { return true } else { return false } }
    private var isReady: Bool { if case .ready = phase { return true } else { return false } }

    private var restTint: Color {
        switch phase {
        case .tasks, .paused, .timeUp: return StatusCardStyle.red
        case .open, .ready: return StatusCardStyle.green
        case .downtime: return downtimeIndigo
        }
    }
}

/// The first task has just locked the child's device: the app dims, the
/// lock shows through a lit circle, and a card centred under it says the
/// device stays locked until the parent approves the work (2026-11-13, the
/// user's call: "more centric, like a shadow tour"; a pop-up under the lock
/// on the page, 2026-11-12, and a line of text before). Add more tasks and
/// Understood; either closes it for good (`evlin.lookAtDevice`).
@MainActor
final class FirstLockSpotlight: ObservableObject {
    static let shared = FirstLockSpotlight()
    /// The lock's frame on screen while the spotlight shows.
    @Published private(set) var lock: CGRect?
    @Published private(set) var childName = ""
    private(set) var addMore: () -> Void = {}

    func show(_ lock: CGRect?, childName: String, addMore: @escaping () -> Void) {
        self.childName = childName
        self.addMore = addMore
        if lock != self.lock { withAnimation(.easeOut(duration: 0.35)) { self.lock = lock } }
    }

    /// Closes it for good.
    func close() {
        UserDefaults.standard.set(false, forKey: StatusPathHeader.lookAtDeviceKey)
        withAnimation(.easeOut(duration: 0.3)) { lock = nil }
    }
}

/// The spotlight itself, over the whole app (`ParentRootView`).
struct FirstLockSpotlightView: View {
    @ObservedObject private var spot = FirstLockSpotlight.shared
    @State private var breathe = false

    var body: some View {
        GeometryReader { g in
            if let lock = spot.lock {
                let origin = g.frame(in: .global).origin
                let hole = lock.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -12, dy: -12)
                ZStack(alignment: .top) {
                    // The dimmed app with the lock cut out.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: g.size))
                        p.addEllipse(in: hole)
                    }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    // A soft ring breathing round the lock.
                    Circle()
                        .stroke(Color.white.opacity(breathe ? 0.10 : 0.28), lineWidth: 2)
                        .frame(width: hole.width + (breathe ? 14 : 2), height: hole.height + (breathe ? 14 : 2))
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                    card
                        .padding(.horizontal, 24)
                        .offset(y: hole.maxY + 20)
                        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(spot.lock != nil)
    }

    private var card: some View {
        let name = spot.childName
        return VStack(spacing: 8) {
            Text("\(name)'s device is now locked")
                .font(Typography.font(19, weight: .semibold))
                .foregroundStyle(EColor.onSurface)
            Text("Pick up \(name)'s device and leave Evlin: every app is locked. It stays locked until the chores are done and you approve them, or you unlock it yourself.")
                .font(Typography.font(15.5, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(EColor.onSurface.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    let add = spot.addMore
                    spot.close()
                    add()
                } label: {
                    Text("Add more tasks")
                        .font(Typography.font(15.5, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(HomeStyle.sunk, in: Capsule())
                }
                Button { spot.close() } label: {
                    Text("Understood")
                        .font(Typography.font(15.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(FormGreen.accent, in: Capsule())
                }
            }
            .buttonStyle(CardPressStyle(haptic: true))
            .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(PopUpShape().fill(EColor.card))
        .overlay(PopUpShape().stroke(HomeStyle.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

/// A rounded card with a small tip at the top middle, pointing up.
private struct PopUpShape: Shape {
    func path(in r: CGRect) -> Path {
        let radius: CGFloat = 18, tipW: CGFloat = 22, tipH: CGFloat = 10
        let card = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        var p = Path(roundedRect: card, cornerRadius: radius, style: .continuous)
        p.move(to: CGPoint(x: card.midX - tipW / 2, y: card.minY + 0.5))
        p.addLine(to: CGPoint(x: card.midX - 3, y: card.minY - tipH + 2))
        p.addQuadCurve(to: CGPoint(x: card.midX + 3, y: card.minY - tipH + 2),
                       control: CGPoint(x: card.midX, y: card.minY - tipH - 1))
        p.addLine(to: CGPoint(x: card.midX + tipW / 2, y: card.minY + 0.5))
        p.closeSubpath()
        return p
    }
}

extension StatusPathHeader.Phase {
    // What the ring shows at rest: what's moving towards the phone opening
    // (tasks done, or everything in and waiting), and the time left once
    // it's open. Locked with time left, out of time, or downtime: empty.
    var fraction: CGFloat {
        switch self {
        case let .tasks(done, total): return total > 0 ? CGFloat(done) / CGFloat(total) : 0
        case let .ready(done, waiting, total): return total > 0 ? min(1, CGFloat(done + waiting) / CGFloat(total)) : 0
        case let .open(_, fraction): return CGFloat(max(0, min(1, fraction)))
        case .paused, .timeUp, .downtime: return 0
        }
    }

    /// The status in words, for inside the bar.
    var words: (text: String, suffix: String?, color: Color) {
        switch self {
        case let .tasks(done, total):
            return ("\(done)", "of \(total) done", EColor.onSurface)
        case let .ready(done, waiting, total):
            // The kid's progress, counting what they've sent in.
            return ("\(done + waiting)", "of \(total) done", EColor.onSurface)
        case let .open(timeLeft, _):
            // Time left in green, the same as the open lock beside it.
            return (timeLeft, "left", StatusCardStyle.green)
        case .paused:
            // Locked by hand: neutral grey in the bar, while the lock icon
            // beside it stays red so the action still reads as a lock.
            return ("Locked", nil, StatusCardStyle.secondaryLabel)
        case .timeUp:
            // Out of time: a quiet grey 0m over the empty bar, not a stark
            // black one; the red lock beside it is the only colour.
            return ("0m", "left", StatusCardStyle.secondaryLabel)
        case let .downtime(until):
            return ("Until \(until)", nil, downtimeIndigo)
        }
    }
}

/// The padlock from the status design, as a path in a 24-point box: the
/// body (x 5, y 11, 14 × 10, corners 2) and the shackle over it. `open`
/// 0 is shut; at 1 the shackle's right side has lifted out of the body and
/// curled back a little (the design's `a5 5 0 0 1 9.9-1`), half open.
/// Animatable, so the shackle swings rather than swapping pictures.
struct LockGlyph: Shape {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        path.addRoundedRect(in: CGRect(origin: p(5, 11), size: CGSize(width: 14 * s, height: 10 * s)),
                            cornerSize: CGSize(width: 2 * s, height: 2 * s))
        // Left leg up, over the top, and (shut) down the right into the body.
        let t = max(0, min(1, open))
        path.move(to: p(7, 11))
        path.addLine(to: p(7, 7))
        let end = 360 - 11.5 * t   // degrees; 348.5 leaves the end at (16.9, 6)
        path.addArc(center: p(12, 7), radius: 5 * s, startAngle: .degrees(180), endAngle: .degrees(end), clockwise: false)
        if t < 1 { path.addLine(to: p(17, 7 + 4 * (1 - t))) }
        return path
    }
}

// One task row: a thin ring, the title, and a calm "day, time" line under
// it. The ring says the state at a glance: the child's colour while to do,
// red with "!" when late, orange when it's waiting on the parent,
// filled with a tick when done. Dashed for tomorrow, which can't be opened
// yet. Hairlines between rows come from the list (taskList), not the row.

struct HomeTaskRow: View {
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
        if waitingOnParent { return HomeStyle.waiting }
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
                    // Done is the progress bar's own green, the same in both
                    // looks (2026-11-14, the user's catch: the child's
                    // #3DAA5C beside the bar's #4CAF6A at night).
                    Circle().fill(StatusCardStyle.green)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    Circle()
                        .strokeBorder(ringColor.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: isTomorrow ? [4, 3] : []))
                    if task.state == .overdue {
                        Image(systemName: "exclamationmark").font(.system(size: 19, weight: .bold)).foregroundStyle(ringColor)
                    }
                }
            }
            // Big rows: a day has two to five chores, and five fill the page.
            .frame(width: 48, height: 48)
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
                    .font(Typography.font(19, weight: .bold))
                    .foregroundStyle(isDone ? HomeStyle.muted : EColor.onSurface)
                    .strikethrough(isDone, color: HomeStyle.muted)
                if let detail {
                    Text(detail)
                        .font(Typography.font(15.5, weight: .regular))
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
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A modern semi-unlocked padlock matching Apple's `lock.fill` in
/// proportions, weight, and continuous corner curvature, with the shackle
/// lifted slightly and cleanly unhooked on the right.

/// One card at the top of Home's Today when the child has checked in on a
/// habit: "Mia's habits need your attention", how many, and a tap takes the
/// parent to the Habits lane to answer them (a list with Approve on each row
/// was tried first, 2026-11-05).
struct HabitCheckInsCard: View {
    var count: Int
    var childName: String
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                HabitLeaf()
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 44)
                    .background(Self.leafBg, in: Circle())
                // Just the line: no count under it (the user's call).
                Text("\(childName)'s habits need your attention")
                    .font(Typography.font(15.5, weight: .bold))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Neutral.secondary)
            }
            .padding(14)
            .background(Self.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.edge, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Habits")
    }

    // A soft cool sage on the cool grey page (2026-11-14; the muted warm
    // sage #E1E5D3 on Alabaster earlier the same day; the pale mint #EAF6ED
    // with a green edge, on a white circle, before: it didn't match).
    static let fill = Color(light: "E2ECE5", dark: "17301F")
    static let edge = Color(light: "BFD4C6", dark: "2A4A33")
    static let leafBg = Color(light: "D0E1D5", dark: "262A30")
}


// MARK: - First task (a child with none yet)

/// Today for a child with no tasks at all: "Add Mia's first task" over the
/// green Add a task button, with a hand tapping that button again and again,
/// so it's plain what to press (2026-11-11, the user's call: a ghost task row
/// whose ring drew round and ticked itself came first, 2026-11-08, and read
/// as a random check). The whole of it opens New task.
struct FirstTaskStart: View {
    let childName: String
    /// Where the words are on screen (nil once gone), for the arrow.
    var onFrame: (CGRect?) -> Void = { _ in }
    let action: () -> Void

    // Just the words, centred in the empty page, with a dotted arrow from
    // them to Home's floating +, which the hand taps (`TappingHand`,
    // `FirstTaskArrow`; 2026-11-12, the user's call: left-aligned words
    // with nothing joining them to the + before, and before that a green
    // "Add a task" pill on the page, tapped by the hand).
    var body: some View {
        Button(action: action) {
            Text("Add \(childName)'s first task")
                .font(Typography.font(21, weight: .semibold))
                .foregroundStyle(EColor.onSurface)
                .multilineTextAlignment(.center)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
                .frame(maxWidth: .infinity)
                .padding(.top, 110)
                .padding(.bottom, 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { onFrame(nil) }
    }
}

/// A dotted line from the first task's words, curving down to the left of
/// the floating +, with an arrowhead pointing into it. It draws itself in
/// once, then holds still.
struct FirstTaskArrow: View {
    let from: CGPoint
    let to: CGPoint
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = EColor.onSurface.opacity(0.4)
        ZStack {
            Curve(from: from, to: to)
                .trim(from: 0, to: drawn)
                .stroke(ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.1, 8]))
            Head(at: to)
                .stroke(ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .opacity(drawn > 0.97 ? 1 : 0)
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { drawn = 1; return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.35)) { drawn = 1 }
        }
    }

    // Down from under the words, then sweeping right into the +.
    private struct Curve: Shape {
        let from: CGPoint, to: CGPoint
        func path(in _: CGRect) -> Path {
            var p = Path()
            p.move(to: from)
            p.addCurve(to: to,
                       control1: CGPoint(x: from.x, y: from.y + (to.y - from.y) * 0.8),
                       control2: CGPoint(x: to.x - (to.x - from.x) * 0.55, y: to.y))
            return p
        }
    }

    // Pointing right: the curve arrives level.
    private struct Head: Shape {
        let at: CGPoint
        func path(in _: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: at.x - 9, y: at.y - 7))
            p.addLine(to: at)
            p.addLine(to: CGPoint(x: at.x - 9, y: at.y + 7))
            return p
        }
    }
}

/// A white hand with a dark edge, as a pointer: it comes over what it
/// wraps, taps it (the content is drawn pressed), lifts, and waits, again
/// and again. Still with Reduce Motion.
struct TappingHand<Content: View>: View {
    @ViewBuilder let content: (_ pressed: Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Beat: CaseIterable { case away, over, press, lift, rest }

    var body: some View {
        PhaseAnimator(reduceMotion ? [Beat.rest] : Beat.allCases) { beat in
            content(beat == .press)
                .overlay { finger(beat) }
        } animation: { beat in
            switch beat {
            case .away: .easeOut(duration: 0.35)
            case .over: .spring(response: 0.55, dampingFraction: 0.85)
            case .press: .easeOut(duration: 0.14)
            case .lift: .spring(response: 0.35, dampingFraction: 0.6)
            case .rest: .easeInOut(duration: 1.3)
            }
        }
    }

    // The fingertip is the glyph's top left, so the glyph sits down and
    // right of the middle to touch it there.
    private func finger(_ beat: Beat) -> some View {
        let shown = beat != .away && beat != .rest
        return Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 30))
            .foregroundStyle(.white)
            .overlay {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 30))
                    .foregroundStyle(EColor.onSurface.opacity(0.85))
            }
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .scaleEffect(beat == .press ? 0.88 : 1, anchor: .topLeading)
            .offset(x: shown ? 12 : 30, y: shown ? (beat == .press ? 12 : 16) : 44)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
