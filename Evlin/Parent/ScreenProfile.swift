import SwiftUI
import UIKit

struct ScreenProfile: View {
    var childId: String
    var onBack: () -> Void
    // Set when this profile IS the screen it's shown on (ScreenHome's
    // single-child demo flow — see its own comment) rather than something
    // pushed over another screen — there's nowhere for the chevron to go
    // back to, so it's hidden instead of sitting there doing nothing.
    var hideBackButton: Bool = false

    @ObservedObject private var child: Child
    // A real Binding into TaskStore's cache, not a local copy — so an
    // approval made here is still there if a notification tap opens
    // TaskReviewDeckView directly (see ScreenHome), and vice versa. Used to
    // be @State seeded once from TaskStore.tasks(for:), which meant each
    // fresh ScreenProfile (or a separately-opened review deck) got its own
    // disconnected copy and silently lost whatever the other one changed.
    @Binding private var tasks: [ChildTask]
    @State private var rulesExpanded = true
    // Which task the parent tapped — opens TaskReviewDeckView starting there
    // (a Tinder-style swipeable queue over `tasks`, not a single-task sheet).
    @State private var reviewStartIndex: Int?
    @State private var showReflection = false
    @State private var editingRule: ChildRule?
    // Was a menu offering "Add Task" or "Add Rule" — rules (including
    // downtime) now come from chat instead, so the "+" goes straight to
    // adding a task, no intermediate menu with a single choice on it.
    @State private var showAddTask = false
    @State private var showUnlockConfirm = false
    @State private var showGrantTimeSheet = false
    @State private var editingScreenTimeLimit = false
    // Turning off the daily limit removes a core protection entirely (not
    // just pausing a parent-authored rule), so it gets a confirm step the
    // other rule toggles don't — see rulesSection's EToggle.
    @State private var showScreenTimeOffConfirm = false
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
    @State private var backPending = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var adaptive: ParentAdaptive { ParentAdaptive(hSizeClass) }

    init(childId: String, onBack: @escaping () -> Void, hideBackButton: Bool = false) {
        self.childId = childId
        self.onBack = onBack
        self.hideBackButton = hideBackButton
        let c = FamilyStore.child(childId)
        _child = ObservedObject(wrappedValue: c)
        _tasks = TaskStore.binding(for: childId)
    }

    // A task due on some other day (tomorrow, via the New Task date
    // picker) isn't part of today's list at all — nil dueDate (every
    // pre-seeded mock task) always counts as visible today.
    private func isDueToday(_ task: ChildTask) -> Bool {
        guard let due = task.dueDate else { return true }
        return Calendar.current.isDateInToday(due)
    }

    private var todaysTasks: [ChildTask] { tasks.filter(isDueToday) }
    private var doneCount: Int { todaysTasks.filter { $0.state == .done }.count }
    private var activeRulesCount: Int { child.rules.filter(\.on).count }

    // True once there's nothing left for the kid to actually do — every
    // task still needing action has already been submitted for review or
    // is asking to bypass, none outstanding or overdue. Screen time stays
    // locked while this holds (there's no "unlock" decision to make, just
    // an approval one), so headerCard swaps the manual lock/unlock slider
    // for a single Approve All button — one tap resolves every review and
    // bypass at once instead of stepping through each task individually.
    private var allTasksAwaitingReview: Bool {
        let outstanding = todaysTasks.contains { $0.state == .pending || $0.state == .overdue }
        let awaiting = todaysTasks.contains { $0.state == .review || $0.state == .bypass }
        return !outstanding && awaiting
    }

    // Mirrors TaskReviewDeckView's own per-task Approve action (.review ->
    // .done, .bypass -> .bypassed) plus the same unlock reset
    // UnlockConfirmCard's onUnlock uses — approving everything is what
    // earns the unlock here, not a separate manual slide.
    private func approveAllPendingReview() {
        for i in tasks.indices where isDueToday(tasks[i]) {
            switch tasks[i].state {
            case .review: tasks[i].state = .done
            case .bypass: tasks[i].state = .bypassed
            default: break
            }
        }
        child.status = .unlocked
        child.timeLeft = formatMinutes(child.dailyLimitMin)
        child.timePct = 100
    }

    // Drives headerCard's "Unlimited screen time today" state — the daily
    // cap only stops applying once this built-in rule is switched off (see
    // ScreenTimeOffConfirmCard), not just because the child happens to be
    // unlocked.
    private var screenTimeLimitOff: Bool {
        !(child.rules.first(where: { $0.kind == .screenTimeLimit })?.on ?? true)
    }

    // Same partitioned time bar as the family dashboard grid (ScreenHome's
    // ProfileBubble) — 30-minute blocks laid out in a row, so "time left"
    // reads identically whether you're looking at the family grid or a
    // single kid's own profile. Fixed brand green rather than the child's
    // own avatar color, matching ScreenHome's ProfileBubble.
    private var barColor: Color { child.status == .unlocked ? Color(hex: "25924A") : Color(hex: "CBD5E1") }

    private var timePoolFilledMinutes: Int {
        guard child.status == .unlocked else { return 0 }
        return Int((Double(child.dailyLimitMin) * Double(child.timePct) / 100).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerCard

                if child.reflection != nil {
                    reflectionSummaryCard
                } else {
                    tasksSection
                }

                rulesSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .parentContentColumn(adaptive.contentMaxWidth)
        }
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
                        .background(Brand.ink)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
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
                        child.status = .unlocked
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
                        child.status = .unlocked
                        child.timeLeft = formatMinutes(minutes)
                        child.timePct = min(100, Int(Double(minutes) / Double(max(child.dailyLimitMin, 1)) * 100))
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
            if showScreenTimeOffConfirm {
                ScreenTimeOffConfirmCard(
                    childName: child.name,
                    onTurnOff: {
                        if let i = child.rules.firstIndex(where: { $0.kind == .screenTimeLimit }) {
                            child.rules[i].on = false
                        }
                        withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = false }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = false } }
                )
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
        .task {
            if child.trialExhausted { withAnimation(.easeOut(duration: 0.2)) { showTrialPopup = true } }
            if child.needsProtectionSetup { withAnimation(.easeOut(duration: 0.2)) { showProtectionSetupPopup = true } }
        }
        .navigationTitle("\(child.name)'s Space")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !hideBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // onBack() dismisses the fullScreenCover this whole
                        // screen lives in (see ScreenHome's openChildId) — a
                        // second tap landing before that animation finishes
                        // would otherwise re-fire onBack() into a screen that's
                        // already mid-teardown, which reads as the button
                        // needing repeated taps to register.
                        guard !backPending else { return }
                        backPending = true
                        onBack()
                    } label: { Image(systemName: "chevron.left") }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { reviewStartIndex != nil }, set: { if !$0 { reviewStartIndex = nil } })) {
            TaskReviewDeckView(tasks: $tasks, childName: child.name, childId: childId, startIndex: reviewStartIndex ?? 0, onDismiss: { reviewStartIndex = nil })
        }
        .sheet(isPresented: $showAddTask) {
            AddTaskSheet(child: child, onCreate: { newTask in
                // The child's very first task ever — flips the phone from
                // .unlocked (nothing to gate yet) to .lockedTasks, a real
                // consequence of assigning work instead of a status the
                // child was just born with. dailyLimitMin (defaulted to 60
                // at onboarding — see FamilyStore.addOnboardedChild) is
                // deliberately left untouched here: a parent could already
                // have customized it in Rules before ever assigning a task,
                // and re-stomping it to the default here would be a bug.
                let isFirstTask = tasks.isEmpty
                let newId = (tasks.map(\.id).max() ?? 0) + 1
                var t = newTask
                t.id = newId
                tasks.append(t)
                if isFirstTask {
                    child.status = .lockedTasks
                }
                showAddTask = false
            }, onCancel: { showAddTask = false })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .interactiveDismissDisabled()
            .presentationDetents([.large])
            .presentationBackground(EColor.surface)
            .presentationDragIndicator(.hidden)
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

    private var headerCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: adaptive.of(18, 24)) {
                    Circle().fill(child.color).frame(width: adaptive.of(64, 84), height: adaptive.of(64, 84))
                        .overlay(Text(String(child.name.prefix(1))).font(Typography.font(adaptive.of(24, 32), weight: .heavy)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(child.name).font(Typography.font(adaptive.of(22, 28), weight: .heavy)).foregroundStyle(EColor.primary)
                        if let r = child.reflection {
                            Label("Under Reflection", systemImage: "figure.mind.and.body")
                                .font(Typography.font(10, weight: .bold))
                                .foregroundStyle(Color(hex: "4A3215"))
                        } else if child.status == .unlocked && screenTimeLimitOff {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Unlimited screen time today", systemImage: "infinity")
                                    .font(Typography.font(12, weight: .bold))
                                    .foregroundStyle(EColor.secondary)
                                Text("Screen Time Limit reapplies tomorrow")
                                    .font(Typography.font(10.5, weight: .medium))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                            }
                        } else if child.status == .unlocked {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(child.timeLeft) left today").font(Typography.font(11, weight: .semibold)).foregroundStyle(Color(hex: "25924A"))
                                SegmentedTimeBar(
                                    totalMinutes: child.dailyLimitMin,
                                    filledMinutes: timePoolFilledMinutes,
                                    filledColor: barColor,
                                    emptyColor: Color(hex: "CBD5E1").opacity(0.35)
                                )
                                .frame(width: 160, height: 7)
                            }
                        } else if child.status == .downtime {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Downtime", systemImage: "moon.fill")
                                    .font(Typography.font(17, weight: .heavy))
                                    .foregroundStyle(downtimeIndigo)
                                Text("Until \(child.downtimeUntil ?? "") tomorrow")
                                    .font(Typography.font(13, weight: .semibold))
                                    .foregroundStyle(downtimeIndigo.opacity(0.8))
                            }
                        } else {
                            Label(child.status == .lockedTasks ? "Locked · \(doneCount)/\(todaysTasks.count) tasks" : "Locked", systemImage: "lock.fill")
                                .font(Typography.font(10, weight: .bold))
                                .foregroundStyle(EColor.danger)
                        }
                    }
                    Spacer()
                }

                if child.status != .downtime, child.reflection == nil, allTasksAwaitingReview {
                    // Nothing to lock or unlock manually right now — the
                    // kid already did their part, so the one action left
                    // is approving it. A plain tap is fine here (unlike
                    // the slider below): approving is the safe, expected
                    // direction, not the "instantly cut a kid off" one
                    // that gesture guards against.
                    PrimaryButton(title: "Approve All", systemIcon: "checkmark.circle.fill", action: approveAllPendingReview)
                        .padding(.top, 16)
                } else if child.status != .downtime, child.reflection == nil {
                    LockActionButton(
                        label: child.status == .unlocked ? "Tap to lock phone" : "Tap to unlock phone",
                        systemImage: child.status == .unlocked ? "lock.fill" : "lock.open.fill",
                        tint: child.status == .unlocked ? Brand.greenDeep : EColor.danger
                    ) {
                        if child.status == .unlocked {
                            // Doesn't touch timeLeft/timePct — a manual lock
                            // is a pause, not the allowance being spent, so
                            // whatever real time was left stays banked
                            // (invisible while locked, since the display
                            // above only reads it in the .unlocked branch)
                            // and comes back as-is on unlock instead of
                            // being reported as used up.
                            child.status = .locked
                        } else if todaysTasks.count - doneCount > 0 {
                            // Unlocking (unlike locking) needs a confirm — it's
                            // the easy-to-regret direction, especially with
                            // chores still open, so don't apply it on the
                            // first tap.
                            withAnimation(.easeOut(duration: 0.2)) { showUnlockConfirm = true }
                        } else if child.timePct > 0 {
                            // Tasks are done and there's still real banked
                            // time (e.g. a one-off manual lock, not the
                            // daily allowance running out) — resume it
                            // directly instead of running the "how much
                            // extra" Grant Time flow, which frames this as
                            // bonus time beyond an exhausted limit.
                            child.status = .unlocked
                        } else {
                            // Tasks are done and the daily allowance is
                            // genuinely used up — the question here isn't
                            // "unlock or not," it's "how much," so ask for
                            // an amount instead of a bare confirm.
                            withAnimation(.easeOut(duration: 0.2)) { showGrantTimeSheet = true }
                        }
                    }
                    .padding(.top, 16)
                }
            }
        }
    }

    // Downtime is a schedule lock owned by the Downtime rule below, not a
    // manual one — so unlike the Lock/Unlock button above, the header shows
    // no controls of its own while it's active. Toggling or deleting the
    // Downtime rule (in rulesSection) is what ends it, via
    // exitDowntimeIfActive.
    private func exitDowntimeIfActive() {
        guard child.status == .downtime else { return }
        child.status = .unlocked
        child.timeLeft = formatMinutes(child.dailyLimitMin)
        child.timePct = 100
        child.downtimeUntil = nil
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No done/total pill here anymore — headerCard's status line
            // ("Locked · 1/5 tasks") already says how many are left, so
            // this was the same count shown twice on one screen.
            SectionHead("Current Tasks")
            VStack(spacing: 10) {
                // Enumerate the full array first, filter after — `i` has
                // to stay the task's true index into `tasks` (what
                // reviewStartIndex/TaskReviewDeckView expect), not its
                // position among just today's visible rows.
                ForEach(Array(tasks.enumerated()).filter { isDueToday($0.element) }, id: \.element.id) { i, task in
                    TaskRowView(task: task, onOpen: { reviewStartIndex = i })
                }
            }
        }
    }

    private var reflectionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("Reflection Assignment") {
                Text("ACTIVE").font(Typography.font(9, weight: .bold)).foregroundStyle(Color(hex: "B26A00"))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Color(hex: "FFF3E0")).clipShape(Capsule())
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Screen time locked · \(child.reflection?.minutes ?? 0) min", systemImage: "lock.fill")
                        .font(Typography.font(11, weight: .bold)).foregroundStyle(Color(hex: "4A3215"))
                    Text("\(child.name) must finish a 3-step reflection")
                        .font(Typography.font(18, weight: .heavy)).foregroundStyle(Color(hex: "2E1F08"))

                    ForEach(Array(ReflectionStep.allCases.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 12) {
                            Image(systemName: EIcon.sf(step.icon)).foregroundStyle(Color(hex: "6E4F26"))
                                .frame(width: 34, height: 34).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step \(step.stepNumber) of 3 — \(step.title)").font(Typography.font(13, weight: .bold)).foregroundStyle(Color(hex: "2E1F08"))
                                Text(step.subtitle).font(Typography.font(11, weight: .regular)).foregroundStyle(Color(hex: "6E4F26"))
                            }
                            Spacer()
                        }
                    }

                    if let r = child.reflection, !r.writtenText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("EVLIN ASKS").font(Typography.font(9, weight: .bold)).foregroundStyle(Color(hex: "15803D"))
                            Text(ReflectionContent.prompt).font(Typography.font(13, weight: .semibold))
                        }
                        .padding(12)
                        .background(Color(hex: "DCFCE7"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text("\"\(r.writtenText)\"")
                            .font(Typography.font(13, weight: .regular))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(EColor.outlineVariant))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        if r.review == "pending" {
                            HStack(spacing: 10) {
                                PrimaryButton(title: "Approve") { child.reflection?.review = "approved" }
                                Button("Request redo") { child.reflection?.review = "redo" }
                                    .font(Typography.font(13, weight: .bold))
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EColor.outlineVariant))
                            }
                        } else {
                            Text(r.review == "approved" ? "You approved this reflection." : "\(child.name) will be asked to write again.")
                                .font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                        }
                    }

                    Button("Cancel reflection") { child.reflection = nil }
                        .font(Typography.font(13, weight: .heavy))
                        .foregroundStyle(Color(hex: "6E4F26"))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: "B7935E")))
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ rule: ChildRule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: EIcon.sf(rule.icon))
                .frame(width: 36, height: 36)
                .background(EColor.primaryContainer)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(EColor.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title).font(Typography.font(14, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text(rule.detail).font(Typography.font(12, weight: .semibold)).foregroundStyle(EColor.primary)
            }
        }
    }

    private var rulesSection: some View {
        Card(padded: false) {
            VStack(spacing: 0) {
                Button { withAnimation { rulesExpanded.toggle() } } label: {
                    HStack {
                        Text("Active Rules").font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
                        Text("\(activeRulesCount)/\(child.rules.count)").font(Typography.font(10, weight: .bold)).foregroundStyle(Color(hex: "25924A"))
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color(hex: "E4F8E9")).clipShape(Capsule())
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if rulesExpanded {
                    ForEach($child.rules) { $rule in
                        Divider().padding(.leading, 16)
                        HStack(spacing: 12) {
                            // Screen Time Limit is a built-in protection — it
                            // can be paused with the toggle and its minutes
                            // adjusted, but (unlike a parent-authored rule)
                            // it can't be deleted, so it opens its own daily-
                            // limit editor instead of the generic rule form.
                            let isBuiltIn = rule.kind == .screenTimeLimit
                            Button {
                                if isBuiltIn { editingScreenTimeLimit = true } else { editingRule = rule }
                            } label: { rowContent(rule) }
                            .buttonStyle(.plain)
                            Spacer(minLength: 12)
                            EToggle(on: Binding(
                                get: { rule.on },
                                set: { newValue in
                                    // Screen Time Limit is the one built-in
                                    // protection here — switching it off
                                    // removes the daily cap entirely, not
                                    // just pausing a rule, so it needs a
                                    // beat to confirm rather than flipping
                                    // instantly like every other toggle.
                                    if rule.kind == .screenTimeLimit && !newValue {
                                        withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = true }
                                        return
                                    }
                                    rule.on = newValue
                                    if rule.kind == .downtime && !newValue { exitDowntimeIfActive() }
                                }
                            ))
                            Button {
                                if isBuiltIn { editingScreenTimeLimit = true } else { editingRule = rule }
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 15))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(16)
                    }
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            EditRuleSheet(rule: rule, onSave: { updated in
                if let i = child.rules.firstIndex(where: { $0.id == updated.id }) { child.rules[i] = updated }
                editingRule = nil
            }, onCancel: { editingRule = nil }, onDelete: {
                child.rules.removeAll { $0.id == rule.id }
                editingRule = nil
                if rule.kind == .downtime { exitDowntimeIfActive() }
            })
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $editingScreenTimeLimit) {
            EditDailyScreenTimeLimitSheet(
                childName: child.name,
                current: child.dailyLimitMin,
                onSave: { limit in
                    child.dailyLimitMin = limit
                    if let i = child.rules.firstIndex(where: { $0.kind == .screenTimeLimit }) {
                        child.rules[i].detail = "\(formatMinutes(limit)) per day"
                    }
                    editingScreenTimeLimit = false
                },
                onCancel: { editingScreenTimeLimit = false }
            )
            .interactiveDismissDisabled()
        }
    }

}

// MARK: - Slide-to-confirm lock/unlock control

// A real drag, not a tap — matching iOS's own "slide to power off," this
// makes the single most consequential action on the profile (instantly
// locking or unlocking a kid's devices) something a parent has to commit
// to, not something a stray tap can trigger the same as any other row.
// `action` fires once the thumb crosses the completion threshold; the
// thumb then eases back to the start so the control is ready to use again
// rather than staying stuck "completed."
// A plain tap button — this used to be a slide-to-confirm gesture (the
// reasoning was that this is the single most consequential control on the
// profile, so it deserved a deliberate gesture instead of an easy-to-misfire
// tap, mirroring iOS's own power-off slider). Reverted back to a button:
// a slide gesture is unfamiliar friction for what parents expect to be a
// one-tap action, and the wording alone ("Tap to lock/unlock phone") already
// tells a parent plainly what tapping it does.
private struct LockActionButton: View {
    var label: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
                Text(label).font(Typography.font(14, weight: .heavy)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 260, height: 48)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
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

// Ported concept from the reflection/earn-back philosophy elsewhere in the
// app: once chores are done, unlocking isn't a "should they" question
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

                    Text("\(childName) finished all their tasks today but has used the full \(formatMinutes(dailyLimitMin)) allowance.")
                        .font(Typography.font(14, weight: .medium))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

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
                    "Locked time is what makes the limits stick. Unlocking early — even occasionally — can undo that and make future locks harder to enforce.")
        }
        let task = remaining == 1 ? "task" : "tasks"
        let text = "\(childName) still has \(remaining) \(task) left to do. Unlocking now teaches them screen time comes before responsibilities — it can build a bad habit."
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
                        cardButton("Unlock anyway", tint: EColor.danger, action: onUnlock)
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

// Screen Time Limit is the one built-in protection in rulesSection — flipping
// it off removes the daily cap entirely (unlimited access until turned back
// on), unlike pausing a parent-authored rule, so it gets its own confirm
// step instead of toggling instantly.
private struct ScreenTimeOffConfirmCard: View {
    var childName: String
    var onTurnOff: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 17))
                            .foregroundStyle(EColor.danger)
                        Text("Turn off Screen Time Limit?")
                            .font(Typography.font(18, weight: .heavy))
                            .foregroundStyle(EColor.onSurface)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(EColor.danger)
                        Text("\(childName) will have unlimited screen time for the rest of today — the daily allowance won't apply at all. The Screen Time Limit rule turns back on by itself tomorrow.")
                            .font(Typography.font(14, weight: .regular))
                            .foregroundStyle(EColor.onSurface)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(EColor.danger.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(spacing: 10) {
                        cardButton("Turn off anyway", tint: EColor.danger, action: onTurnOff)
                        cardButton("Keep it on", tint: EColor.onSurfaceVariant, action: onCancel)
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

// MARK: - Rule type metadata

// Mirrors RULE_TYPES in index.html:2157 — each kind has one fixed icon and
// builds its own detail string from typed fields.
private enum RuleTypeMeta {
    static func label(_ kind: RuleKind) -> String {
        switch kind {
        case .downtime: return "Downtime"
        case .custom: return "Custom rule"
        case .screenTimeLimit: return "Screen Time Limit"
        }
    }
    static func icon(_ kind: RuleKind) -> String {
        switch kind {
        case .downtime: return "dark_mode"
        case .custom: return "shield"
        case .screenTimeLimit: return "sf:hourglass"
        }
    }
    static func blurb(_ kind: RuleKind) -> String {
        switch kind {
        case .downtime: return "A daily break from the screen — only phone calls and apps you allow will work."
        case .custom: return ""
        case .screenTimeLimit: return "The daily screen time allowance — a core protection you can pause but not edit or remove here."
        }
    }
}

// What a TypeChip shows above its label: an icon (rule types) or a colored
// dot (task categories) — same bordered-box selector, different glyph.
private enum ChipGlyph {
    case icon(String)
    case dot(Color?)
}

// Bordered glyph-over-label box — matches the rule-type picker in
// AddRuleForm (index.html:2098). Reused for Add Task's category picker so
// both "type" selectors in the add sheets share one visual language instead
// of the pill-shaped DotChip used for "For"/"Repeats".
private struct TypeChip: View {
    var glyph: ChipGlyph
    var label: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                switch glyph {
                case .icon(let name):
                    Image(systemName: EIcon.sf(name)).font(.system(size: 20))
                case .dot(let color):
                    Circle().fill(color ?? EColor.onSurfaceVariant).frame(width: 10, height: 10)
                }
                Text(label).font(Typography.font(12, weight: .bold))
            }
            .foregroundStyle(selected ? EColor.primary : EColor.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? EColor.primary.opacity(0.06) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? EColor.primary : EColor.outlineVariant, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

private func ruleTimeField(label: String?, date: Binding<Date>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        if let label {
            Text(label.uppercased()).font(Typography.font(10, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant)
        }
        DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .padding(.horizontal, 14)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    .frame(maxWidth: .infinity)
}

// MARK: - Edit Rule

private struct EditRuleSheet: View {
    @State var rule: ChildRule
    var onSave: (ChildRule) -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var showDeleteConfirm = false

    var body: some View {
        FormShell(title: rule.kind == .custom ? "Edit Rule" : RuleTypeMeta.label(rule.kind), onCancel: onCancel, onSave: {
            var updated = rule
            if updated.kind == .downtime {
                updated.detail = "\(ChildRule.fmtClock(updated.downtimeFrom)) – \(ChildRule.fmtClock(updated.downtimeTo))"
            }
            onSave(updated)
        }, canSave: !rule.title.trimmingCharacters(in: .whitespaces).isEmpty, onDelete: onDelete != nil ? { showDeleteConfirm = true } : nil) {
            switch rule.kind {
            case .downtime:
                FormField(label: "Schedule") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ruleTimeField(label: "From", date: $rule.downtimeFrom)
                            ruleTimeField(label: "To", date: $rule.downtimeTo)
                        }
                        Text(RuleTypeMeta.blurb(.downtime)).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
            case .custom:
                FormField(label: "Rule name") {
                    FormTextField(placeholder: "e.g. No games at dinner", text: $rule.title)
                }
                FormField(label: "Details") {
                    TextField("What this rule does…", text: $rule.detail, axis: .vertical)
                        .font(Typography.font(15, weight: .regular))
                        .lineLimit(2...4)
                        .padding(14)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            case .screenTimeLimit:
                // Unreachable in practice — rulesSection never routes a
                // screenTimeLimit row into this sheet — kept only so the
                // switch stays exhaustive.
                EmptyView()
            }
        }
        // Trash icon lives in FormShell's top header now (next to Cancel),
        // matching EditTaskReviewSheet's delete affordance — same alert,
        // just triggered from the header button instead of a bottom row.
        .alert("Delete \"\(rule.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - Edit Screen Time Limit

// The daily allowance backing the built-in Screen Time Limit rule — a quick-
// pick row of common limits plus a stepper for fine-tuning, mirroring the
// preset-chip pattern GrantExtraTimeSheet uses for "how much extra time."
// Replaces the old single flat Stepper — a parent can now set a different
// limit for each day of the week, using a native scrolling wheel picker for
// the actual minutes (per the "scroll time limits per day" ask) rather than
// tapping a stepper 15 minutes at a time. The day chips switch which day's
// value the wheel is currently showing/editing; nothing saves until "Save
// limits" is tapped, so switching days to peek doesn't lose edits.
private struct EditDailyScreenTimeLimitSheet: View {
    var childName: String
    var current: Int
    var onSave: (Int) -> Void
    var onCancel: () -> Void

    @State private var limit: Int
    @State private var scrollID: Int?

    init(childName: String, current: Int, onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.childName = childName
        self.current = current
        self.onSave = onSave
        self.onCancel = onCancel
        _limit = State(initialValue: current)
        _scrollID = State(initialValue: current)
    }

    private let options: [Int] = Array(stride(from: 15, through: 480, by: 15))
    private let warningStart = 135 // 2h15m
    private let threeHours = 180

    // Mirrors the general pediatric guideline that recreational screen time
    // above ~2 hours/day is worth a second look, and above 3 is worth an
    // explicit flag — not a hard block, just something a parent should see
    // before confirming.
    private var warning: (color: Color, icon: String, text: String)? {
        switch limit {
        case warningStart..<threeHours:
            return (Color(hex: "B26A00"), "exclamationmark.triangle.fill",
                    "\(formatMinutes(limit)) a day is at the upper end of the general screen-time guideline for kids.")
        case threeHours...:
            return (EColor.danger, "exclamationmark.octagon.fill",
                    "\(formatMinutes(limit)) a day is above the general guideline — extended screen time like this is linked to worse sleep, mood, and attention in children.")
        default:
            return nil
        }
    }

    // A UIPickerView-backed wheel Picker only reports its selection on
    // settle, not continuously during a fast fling — the warning message
    // below it visibly lagged behind the finger. A ScrollView driven by
    // live scroll geometry (.scrollPosition) reports position continuously
    // instead, so the warning keeps pace with the flick. Vertical, back to
    // the up/down feel of a standard wheel picker (tried horizontal for a
    // stretch, matching GrantExtraTimeSheet's ruler, but it read as a thin
    // strip of mostly-empty space rather than a real picker).
    private var limitWheel: some View {
        let itemHeight: CGFloat = 46
        let visibleRows: CGFloat = 5
        return GeometryReader { geo in
            let topInset = max(0, (geo.size.height - itemHeight) / 2)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { m in
                        Text(formatMinutes(m))
                            .font(Typography.font(m == limit ? 17 : 14, weight: m == limit ? .heavy : .semibold))
                            .foregroundStyle(m == limit ? EColor.primary : EColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .frame(height: itemHeight)
                            .id(m)
                    }
                }
                .frame(maxWidth: .infinity)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollID)
            .contentMargins(.vertical, topInset, for: .scrollContent)
            .overlay {
                Capsule()
                    .fill(EColor.primary.opacity(0.1))
                    .frame(height: itemHeight - 8)
                    .padding(.horizontal, 32)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: itemHeight * visibleRows)
        .onChange(of: scrollID) { _, newValue in
            if let newValue { limit = newValue }
        }
    }

    var body: some View {
        FormShell(
            title: "Screen Time Limit",
            onCancel: onCancel,
            onSave: { onSave(limit) },
            canSave: limit > 0,
            saveLabel: "Save limit"
        ) {
            FormField(label: "Daily limit") {
                limitWheel
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // No animation here — the wheel picker can fire many `limit`
            // changes per second while scrolling, and an animated cross-fade
            // couldn't keep up, reading as visibly lagging behind the wheel.
            // Updates instantly instead, in lockstep with the scroll.
            if let warning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: warning.icon).foregroundStyle(warning.color)
                    Text(warning.text).font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurface)
                }
                .padding(14)
                .background(warning.color.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transaction { $0.animation = nil }
            }

            Text("\(childName)'s daily allowance resets at midnight.")
                .font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
        }
    }
}

private let bypassPurple = Color(hex: "7C3AED")

private struct TaskRowView: View {
    var task: ChildTask
    var onOpen: () -> Void

    // dueLabel is stored as "Today, 1:00 PM" / "Yesterday, 5:00 PM" — the row
    // only has room for a quick glance, and task.state's own pill (Pending,
    // Overdue, …) already says whether it's on-time, so the day word here is
    // redundant. Just the clock time is enough.
    private func timeOnly(_ label: String) -> String {
        label.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
    }

    // Each task is its own floating card (ported 1:1 from the real app's
    // Components/TaskRow.swift) — not rows sharing one card with dividers.
    // .review used to get the same full-wash treatment as overdue/bypass
    // (a saturated orange background + a matching icon + a matching "Needs
    // review" pill, three cues all saying the same thing). That's fine for
    // one row, but a parent with several submissions waiting sees a wall of
    // identical orange cards that's hard to tell apart and that buries the
    // genuinely urgent state (overdue, in red) in the noise. Review is a
    // routine, positive state — the kid did the work — so it now sits on
    // the same plain card as a done/pending task and leans on the orange
    // icon badge alone as its one cue, instead of three.
    private var cardBackground: Color {
        switch task.state {
        case .overdue: return Color(hex: "FFF5F3")
        case .bypass: return Color(hex: "F7F2FF")
        default: return EColor.surfaceContainerLowest
        }
    }

    // Approve/Redo (and Allow/Deny for a bypass request) used to live
    // inline here too, duplicating what tapping into the task already
    // offers via TaskReviewDeckView — a parent reviewing a submission
    // needs to actually look at it first anyway, so the row is just an
    // entry point now, not a second place to act without opening it.
    var body: some View {
        Button(action: onOpen) {
            mainRow
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(EColor.outlineVariant.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var mainRow: some View {
        HStack(spacing: 14) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(Typography.font(16, weight: .heavy))
                    .foregroundStyle(task.state == .done ? EColor.onSurfaceVariant : EColor.primary)
                    .strikethrough(task.state == .done, color: EColor.onSurfaceVariant)
                HStack(spacing: 6) {
                    trailingLabel
                    // Approve/Redo (review) and Allow/Deny (bypass) rows already have a
                    // submission to act on — the due time only matters before that, so
                    // it's shown for tasks still awaiting one.
                    if let due = task.dueLabel, task.state != .review, task.state != .bypass {
                        Text(timeOnly(due)).font(Typography.font(11, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(EColor.outline)
        }
    }

    @ViewBuilder
    private var trailingLabel: some View {
        switch task.state {
        case .done:
            pill("Done", fg: Color(hex: "25924A"), bg: Color(hex: "E4F8E9"))
        case .review:
            // No pill — the orange camera-icon badge (see statusIcon) is
            // already the state's one cue; repeating "Needs review" in text
            // next to it on every row is what made a short list of
            // submissions read as noise instead of a few distinct tasks.
            EmptyView()
        case .pending:
            pill("Pending", fg: EColor.outline, bg: EColor.surfaceContainerHigh)
        case .overdue:
            Text("OVERDUE").font(Typography.font(11, weight: .heavy)).tracking(1.4).foregroundStyle(EColor.danger)
        case .bypass:
            Text("BYPASS REQUESTED")
                .font(Typography.font(10, weight: .heavy)).tracking(1.2)
                .foregroundStyle(bypassPurple)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(bypassPurple.opacity(0.12)).clipShape(Capsule())
        case .bypassed:
            pill("Bypassed", fg: EColor.outline, bg: EColor.surfaceContainerHigh)
        }
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(Typography.font(11, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(bg).clipShape(Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "25924A"))
                Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        case .review:
            // Hourglass, not a camera — a camera reads as "take a photo,"
            // which is the kid's action, not what a parent glancing at this
            // row needs to know. Matches ScreenTabletHome's own task chip
            // for the exact same state from the kid's side ("Waiting for
            // your parent to check it"), so the same underlying state reads
            // consistently as "something's pending" on both ends.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "EF6C00"))
                Image(systemName: "hourglass").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        case .pending:
            Circle().stroke(EColor.outline, lineWidth: 1.5).frame(width: 28, height: 28).padding(4)
        case .overdue:
            ZStack {
                Circle().stroke(EColor.danger, lineWidth: 1.5)
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(EColor.danger)
            }
            .frame(width: 28, height: 28).padding(4)
        case .bypass:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bypassPurple)
                Image(systemName: EIcon.sf("pan_tool")).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        case .bypassed:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(EColor.outlineVariant, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EColor.surfaceContainerLowest))
                Image(systemName: EIcon.sf("block")).font(.system(size: 14, weight: .heavy)).foregroundStyle(EColor.outline)
            }
            .frame(width: 36, height: 36)
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
    @State private var dueDate = Date()
    @State private var hasDueDate = false
    @State private var repeatDays: Set<String> = []
    // AddTaskFormFields is shared with Calendar's own Add Task, which
    // isn't scoped to one child and needs a real personId binding — this
    // sheet is already scoped via `child`, so it's seeded once and never
    // surfaced (fixedChild hides the For picker that would otherwise show it).
    @State private var personId: String

    init(child: Child, onCreate: @escaping (ChildTask) -> Void, onCancel: @escaping () -> Void) {
        self.child = child
        self.onCreate = onCreate
        self.onCancel = onCancel
        _personId = State(initialValue: child.id)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        AddTaskFormFields(
            title: "New task", saveLabel: "Create task", fixedChild: child,
            taskTitle: $title, personId: $personId, whatToDo: $description, repeatDays: $repeatDays,
            canSave: canSave, onCancel: onCancel, onSave: {
                let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
                onCreate(ChildTask(
                    id: UUID().uuidString, title: title, state: .pending, category: category,
                    description: description, note: nil, submittedAt: nil,
                    dueLabel: hasDueDate ? formatted(dueDate) : nil, dueDate: hasDueDate ? dueDate : nil, photoCount: 0,
                    repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
                ))
            }
        ) {
            TaskWhenField(hasDueDate: $hasDueDate, dueDate: $dueDate)
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f.string(from: date)
    }
}

