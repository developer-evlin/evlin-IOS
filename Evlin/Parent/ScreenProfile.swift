import SwiftUI

struct ScreenProfile: View {
    var childId: String
    var onBack: () -> Void
    // Spotlight walkthrough shown the first time a parent reaches their
    // (default) first child's profile after onboarding — see
    // AddTaskTutorialOverlay below. Session-only, same convention as
    // RootView's `onboarded`/`taskTutorialDone`.
    var startInTutorial: Bool = false
    var onTutorialCompleted: (() -> Void)? = nil
    // Set when this profile was opened by tapping a notification about a
    // specific task (e.g. "Liam finished homework") — jumps straight into
    // TaskReviewDeckView at that task instead of landing on the plain
    // profile and making the parent find it themselves.
    var openTaskId: Int? = nil

    @ObservedObject private var child: Child
    @State private var tasks: [ChildTask]
    @State private var rules: [ChildRule]
    @State private var rulesExpanded = true
    // Which task the parent tapped — opens TaskReviewDeckView starting there
    // (a Tinder-style swipeable queue over `tasks`, not a single-task sheet).
    @State private var reviewStartIndex: Int?
    @State private var showReflection = false
    @State private var editingRule: ChildRule?
    @State private var addMode: AddMode?
    @State private var tutorialActive: Bool
    // A fixed height, not a measured one — `.presentationDetents` doesn't
    // reliably pick up a height correction delivered async (via
    // GeometryReader + PreferenceKey) after the sheet has already started
    // presenting, which showed up as a chunk of dead space below "Add Rule"
    // sized to the stale initial guess. This menu's content (title + exactly
    // two fixed-height rows) never actually changes shape, so a calibrated
    // constant is both simpler and correct where the measured version wasn't.
    private let addMenuHeight: CGFloat = 280
    @State private var showUnlockConfirm = false
    @State private var showGrantTimeSheet = false
    @State private var editingScreenTimeLimit = false
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

    enum AddMode: String, Identifiable { case menu, task, rule
        var id: String { rawValue }
    }

    init(childId: String, onBack: @escaping () -> Void, startInTutorial: Bool = false, onTutorialCompleted: (() -> Void)? = nil, openTaskId: Int? = nil) {
        self.childId = childId
        self.onBack = onBack
        self.startInTutorial = startInTutorial
        self.onTutorialCompleted = onTutorialCompleted
        self.openTaskId = openTaskId
        let c = FamilyStore.child(childId)
        _child = ObservedObject(wrappedValue: c)
        let taskList = TaskStore.tasks(for: childId)
        _tasks = State(initialValue: taskList)
        _rules = State(initialValue: TaskStore.rules(for: c))
        _tutorialActive = State(initialValue: startInTutorial)
        if let openTaskId, let index = taskList.firstIndex(where: { $0.id == openTaskId }) {
            _reviewStartIndex = State(initialValue: index)
        }
    }

    private var doneCount: Int { tasks.filter { $0.state == .done }.count }
    private var activeRulesCount: Int { rules.filter(\.on).count }

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
        }
        .background(EColor.surface)
        // A safeAreaInset (not a ZStack + guessed bottom padding) reserves
        // real layout space for the FAB, so the scroll content's last row —
        // e.g. a rule's description/toggle — can never end up rendered
        // underneath it, regardless of how long or short the list is.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button { addMode = .menu } label: {
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
                    remaining: tasks.count - doneCount,
                    onUnlock: {
                        child.status = .unlocked
                        child.timeLeft = formatMinutes(child.dailyLimitMin)
                        child.timePct = 100
                        showUnlockConfirm = false
                    },
                    onCancel: { showUnlockConfirm = false }
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
                    child.parentApprovalStatus = .approved
                    showApprovalVerify = false
                }
            }
        }
        // Spotlight tutorial goes on top of everything else, including the
        // unlock-confirm card above — it's the one thing allowed to be
        // interactive while it's active.
        .overlay {
            if tutorialActive {
                AddTaskTutorialOverlay(childName: child.name) { addMode = .task }
                    .transition(.opacity)
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
                    onDismiss: { showTrialPopup = false }
                )
            }
        }
        .task {
            if child.trialExhausted { showTrialPopup = true }
        }
        .animation(.easeOut(duration: 0.2), value: showUnlockConfirm)
        .animation(.easeOut(duration: 0.2), value: showApprovalVerify)
        .animation(.easeOut(duration: 0.25), value: tutorialActive)
        .animation(.easeOut(duration: 0.2), value: showTrialPopup)
        .animation(.easeOut(duration: 0.2), value: child.parentApprovalStatus)
        .navigationTitle("\(child.name)'s Space")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Locked out along with everything else until the first
                // task is created — leaving would defeat the walkthrough.
                Button { onBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(tutorialActive)
                    .opacity(tutorialActive ? 0.3 : 1)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { reviewStartIndex != nil }, set: { if !$0 { reviewStartIndex = nil } })) {
            TaskReviewDeckView(tasks: $tasks, childName: child.name, startIndex: reviewStartIndex ?? 0, onDismiss: { reviewStartIndex = nil })
        }
        // One sheet, contents swapped by `addMode` — mirrors AddBottomSheet in
        // index.html, which keeps a single sliding sheet and re-renders its
        // body between the menu / AddTaskForm / AddRuleForm rather than
        // presenting a new sheet per destination.
        .sheet(item: $addMode) { mode in
            Group {
                switch mode {
                case .menu:
                    AddMenuView(childName: child.name) { addMode = $0 }
                case .task:
                    AddTaskSheet(child: child, onCreate: { newTask in
                        let newId = (tasks.map(\.id).max() ?? 0) + 1
                        var t = newTask
                        t.id = newId
                        tasks.append(t)
                        addMode = nil
                        if tutorialActive {
                            tutorialActive = false
                            onTutorialCompleted?()
                        }
                    }, onCancel: { addMode = nil })
                case .rule:
                    AddRuleSheet(onCreate: { newRule in
                        rules.append(newRule)
                        addMode = nil
                    }, onCancel: { addMode = nil })
                }
            }
            // Forms fill the whole large sheet (they need room to scroll and
            // grow with the keyboard) — but the menu must NOT be forced to
            // fill, matching its fixed, non-scrolling content.
            .frame(maxWidth: .infinity, maxHeight: mode == .menu ? nil : .infinity, alignment: .top)
            // The menu step can be swiped away like the web app's tap-outside
            // backdrop; once a form is showing, swipe-to-dismiss turns off so
            // a stray drag can't silently discard a half-filled task/rule
            // (Cancel is the only way out from there, same as FormShell).
            .interactiveDismissDisabled(mode != .menu)
            // The menu uses a calibrated fixed height (see addMenuHeight
            // above) instead of a measured one. Forms stay at .large since
            // they're taller and need room to grow with the keyboard.
            .presentationDetents(mode == .menu ? [.height(addMenuHeight)] : [.large])
            // presentationBackground (not a plain .background() on the
            // content) is what actually paints behind the grab-handle strip
            // and any leftover space below short content — a content-level
            // .background() only covers the content's own hugged height,
            // which is exactly what let the blurred backdrop show through
            // above and below the "Add new" menu.
            .presentationBackground(EColor.surface)
            .presentationDragIndicator(mode == .menu ? .visible : .hidden)
        }
    }

    private func setState(_ id: Int, _ state: TaskState) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state }
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
                .onTapGesture { child.parentApprovalStatus = .none }

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
                        cardButton("Approve", tint: Brand.greenDeep, filled: true) { showApprovalVerify = true }
                        cardButton("Not now", tint: EColor.onSurfaceVariant, filled: false) { child.parentApprovalStatus = .none }
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                HStack(spacing: 18) {
                    Circle().fill(child.color).frame(width: 64, height: 64)
                        .overlay(Text(String(child.name.prefix(1))).font(Typography.font(24, weight: .heavy)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(child.name).font(Typography.font(22, weight: .heavy)).foregroundStyle(EColor.primary)
                        if let r = child.reflection {
                            Label("Under Reflection", systemImage: "figure.mind.and.body")
                                .font(Typography.font(10, weight: .bold))
                                .foregroundStyle(Color(hex: "4A3215"))
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
                            Label(child.status == .lockedTasks ? "Locked · \(child.tasksDone)/\(child.tasksTotal) tasks" : "Locked", systemImage: "lock.fill")
                                .font(Typography.font(10, weight: .bold))
                                .foregroundStyle(EColor.danger)
                        }
                    }
                    Spacer()
                }

                if child.status != .downtime, child.reflection == nil {
                    Button {
                        if child.status == .unlocked {
                            child.status = .locked; child.timeLeft = "0m"; child.timePct = 0
                        } else if tasks.count - doneCount > 0 {
                            // Unlocking (unlike locking) needs a confirm — it's
                            // the easy-to-regret direction, especially with
                            // chores still open, so don't apply it on the
                            // first tap.
                            showUnlockConfirm = true
                        } else {
                            // Tasks are already done — the risk here isn't
                            // "unlocking before chores," it's "how much," so
                            // ask for an amount instead of a bare confirm.
                            showGrantTimeSheet = true
                        }
                    } label: {
                        Label(child.status == .unlocked ? "Lock \(child.name)'s devices" : "Unlock \(child.name)'s devices",
                              systemImage: child.status == .unlocked ? "lock.fill" : "lock.open.fill")
                            .font(Typography.font(14, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(child.status == .unlocked ? Brand.greenDeep : EColor.danger)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .sheet(isPresented: $showGrantTimeSheet) {
                        GrantExtraTimeSheet(
                            childName: child.name,
                            dailyLimitMin: child.dailyLimitMin,
                            usageTodayMin: child.usageTodayMin,
                            onGrant: { minutes in
                                child.status = .unlocked
                                child.timeLeft = formatMinutes(minutes)
                                child.timePct = min(100, Int(Double(minutes) / Double(max(child.dailyLimitMin, 1)) * 100))
                                showGrantTimeSheet = false
                            },
                            onCancel: { showGrantTimeSheet = false }
                        )
                    }
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
            SectionHead("Current Tasks") {
                Text("\(doneCount)/\(tasks.count)")
                    .font(Typography.font(11, weight: .heavy))
                    .foregroundStyle(Color(hex: "25924A"))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color(hex: "E4F8E9"))
                    .clipShape(Capsule())
            }
            VStack(spacing: 10) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                    TaskRowView(task: task, onOpen: { reviewStartIndex = i }, onApprove: { setState(task.id, task.state == .bypass ? .bypassed : .done) }, onRedo: { setState(task.id, .pending) })
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
                HStack(spacing: 4) {
                    Text(rule.detail).font(Typography.font(12, weight: .semibold)).foregroundStyle(EColor.primary)
                    Text("· Tap to change")
                        .font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                }
            }
        }
    }

    private var rulesSection: some View {
        Card(padded: false) {
            VStack(spacing: 0) {
                Button { withAnimation { rulesExpanded.toggle() } } label: {
                    HStack {
                        Text("Active Rules").font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
                        Text("\(activeRulesCount)/\(rules.count)").font(Typography.font(10, weight: .bold)).foregroundStyle(Color(hex: "25924A"))
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color(hex: "E4F8E9")).clipShape(Capsule())
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if rulesExpanded {
                    ForEach($rules) { $rule in
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
                if let i = rules.firstIndex(where: { $0.id == updated.id }) { rules[i] = updated }
                editingRule = nil
            }, onCancel: { editingRule = nil }, onDelete: {
                rules.removeAll { $0.id == rule.id }
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
                    if let i = rules.firstIndex(where: { $0.kind == .screenTimeLimit }) {
                        rules[i].detail = "\(formatMinutes(limit)) per day"
                    }
                    editingScreenTimeLimit = false
                },
                onCancel: { editingScreenTimeLimit = false }
            )
            .interactiveDismissDisabled()
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

            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(EColor.primaryContainer)
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "sparkles").font(.system(size: 19, weight: .semibold)).foregroundStyle(EColor.primary))

                    Text("You've used your free trial")
                        .font(Typography.font(18, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                    Text("Upgrade to Evlin Plus to keep managing \(childName)'s screen time, tasks, and rules.")
                        .font(Typography.font(13, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(childName) finished all their tasks today but has used the full \(formatMinutes(dailyLimitMin)) allowance.")
                        .font(Typography.font(14, weight: .medium))
                        .foregroundStyle(EColor.onSurfaceVariant)

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

                    VStack(alignment: .leading, spacing: 10) {
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

                        if isCustomActive {
                            customRuler
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

                    PrimaryButton(title: "Give \(formatMinutes(selected)) more") { onGrant(selected) }

                    Button("Cancel", action: onCancel)
                        .font(Typography.font(14, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .padding(20)
            }
            .navigationTitle("Give \(childName) more time?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", action: onCancel) } }
        }
        .presentationDetents([.medium])
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
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

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
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

// MARK: - First-task spotlight tutorial

// Punches a visual + interactive "hole" in a view, revealing whatever sits
// beneath it instead of covering it — used below to spotlight the real FAB
// through the dimming scrim rather than drawing a fake copy over it.
private extension View {
    func reverseMask<Mask: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}

// Locks the rest of this screen (and, since it's presented as a
// fullScreenCover over the whole tab bar, the rest of the app) behind a
// dimmed scrim with one spotlighted hole over the "+" FAB, plus a callout
// explaining what to do. Nothing here is skippable — the only way out is
// tapping the hole and actually creating a task (see the `.task` case of
// ScreenProfile's addMode sheet, which clears `tutorialActive`).
private struct AddTaskTutorialOverlay: View {
    var childName: String
    var onTapAddTask: () -> Void

    // Mirrors the real FAB's geometry in ScreenProfile's safeAreaInset
    // exactly (56pt circle, trailing 20 / bottom 16) so the spotlight lines
    // up with the button underneath instead of approximating its position.
    private let fabSize: CGFloat = 56
    private let fabTrailing: CGFloat = 20
    private let fabBottom: CGFloat = 16
    private let holePad: CGFloat = 8
    private var holeDiameter: CGFloat { fabSize + holePad * 2 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .reverseMask(alignment: .bottomTrailing) {
                    Circle()
                        .frame(width: holeDiameter, height: holeDiameter)
                        .padding(.trailing, fabTrailing - holePad)
                        .padding(.bottom, fabBottom - holePad)
                }
                // Absorbs every tap outside the hole so nothing underneath
                // (rules, lock button, back button) is reachable.
                .contentShape(Rectangle())
                .onTapGesture {}

            Circle()
                .strokeBorder(Color.white, lineWidth: 3)
                .frame(width: holeDiameter, height: holeDiameter)
                .padding(.trailing, fabTrailing - holePad)
                .padding(.bottom, fabBottom - holePad)
                .allowsHitTesting(false)

            // The real FAB shows through the hole unchanged; this invisible
            // button sits in front of it so the tutorial controls exactly
            // what tapping it does (jump straight to the task form, not the
            // add-menu chooser).
            Button(action: onTapAddTask) {
                Color.clear.frame(width: holeDiameter, height: holeDiameter)
            }
            .padding(.trailing, fabTrailing - holePad)
            .padding(.bottom, fabBottom - holePad)

            calloutCard
                .padding(.trailing, fabTrailing)
                .padding(.bottom, fabBottom + holeDiameter + 16)
        }
    }

    private var calloutCard: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Add \(childName)'s first task")
                .font(Typography.font(15, weight: .heavy))
                .foregroundStyle(.white)
            Text("Tap + to create a chore or homework task — the rest of Evlin unlocks once \(childName) has something to do.")
                .font(Typography.font(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 270, alignment: .trailing)
        .background(EColor.primary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: - Add menu

// Ported 1:1 from AddMenu in index.html:1866 — a titled list of two big
// tappable rows (icon box, title, subtitle, chevron), not a native context
// menu. Picking a row swaps this same sheet's content via `setMode`.
private struct AddMenuRow: View {
    var icon: String
    var label: String
    var sub: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: EIcon.sf(icon))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(EColor.primary)
                    .frame(width: 48, height: 48)
                    .background(EColor.primaryContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
                    Text(sub).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(EColor.outline)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AddMenuView: View {
    var childName: String
    var setMode: (ScreenProfile.AddMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add new")
                .font(Typography.font(18, weight: .heavy))
                .foregroundStyle(EColor.primary)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            AddMenuRow(icon: "sf:checklist", label: "Add Task", sub: "New chore or homework for \(childName)") {
                setMode(.task)
            }
            Divider().padding(.leading, 12)
            AddMenuRow(icon: "sf:shield", label: "Add Rule", sub: "New screen-time or routine rule") {
                setMode(.rule)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        // Bottom breathing room below the last row so it doesn't sit flush
        // against the sheet's edge — the addMenuHeight constant above is
        // calibrated to this exact padding value.
        .padding(.bottom, 28)
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

    init(childName: String, current: Int, onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.childName = childName
        self.current = current
        self.onSave = onSave
        self.onCancel = onCancel
        _limit = State(initialValue: current)
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

    var body: some View {
        FormShell(
            title: "Screen Time Limit",
            onCancel: onCancel,
            onSave: { onSave(limit) },
            canSave: limit > 0,
            saveLabel: "Save limit"
        ) {
            FormField(label: "Daily limit") {
                VStack(spacing: 0) {
                    Picker("", selection: $limit) {
                        ForEach(options, id: \.self) { m in
                            Text(formatMinutes(m)).tag(m)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 150)
                }
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

// MARK: - Add Rule

// Ported 1:1 from AddRuleForm in index.html:2069 — pick a type first
// (Downtime / Custom), then fill only the fields that fit it.
private struct AddRuleSheet: View {
    var onCreate: (ChildRule) -> Void
    var onCancel: () -> Void

    @State private var kind: RuleKind = .downtime
    @State private var title = ""
    @State private var detail = ""
    @State private var downtimeFrom = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var downtimeTo = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()

    private var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? RuleTypeMeta.label(kind) : trimmed
    }

    private var canSave: Bool {
        kind == .custom ? !detail.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        FormShell(title: "New Rule", onCancel: onCancel, onSave: {
            switch kind {
            case .downtime:
                onCreate(ChildRule(
                    id: UUID().uuidString, kind: .downtime, icon: RuleTypeMeta.icon(.downtime), title: effectiveTitle,
                    detail: "\(ChildRule.fmtClock(downtimeFrom)) – \(ChildRule.fmtClock(downtimeTo))", on: true,
                    downtimeFrom: downtimeFrom, downtimeTo: downtimeTo
                ))
            case .custom:
                onCreate(ChildRule(id: UUID().uuidString, kind: .custom, icon: RuleTypeMeta.icon(.custom), title: effectiveTitle, detail: detail, on: true))
            case .screenTimeLimit:
                // Unreachable — the type picker below only offers Downtime
                // and Custom; Screen Time Limit is a built-in, not something
                // a parent can create another of.
                break
            }
        }, canSave: canSave, saveLabel: "Save") {
            FormField(label: "Rule type") {
                HStack(spacing: 8) {
                    TypeChip(glyph: .icon(RuleTypeMeta.icon(.downtime)), label: "Downtime", selected: kind == .downtime) { kind = .downtime }
                    TypeChip(glyph: .icon(RuleTypeMeta.icon(.custom)), label: "Custom", selected: kind == .custom) { kind = .custom }
                }
            }

            if kind == .downtime {
                FormField(label: "Schedule") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ruleTimeField(label: "From", date: $downtimeFrom)
                            ruleTimeField(label: "To", date: $downtimeTo)
                        }
                        Text(RuleTypeMeta.blurb(.downtime)).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
                FormField(label: "Name (optional)") {
                    FormTextField(placeholder: RuleTypeMeta.label(kind), text: $title)
                }
            }

            if kind == .custom {
                FormField(label: "Describe the rule") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("e.g. No phones at dinner, 6:00–7:00 PM", text: $detail, axis: .vertical)
                            .font(Typography.font(15, weight: .regular))
                            .lineLimit(3...5)
                            .padding(14)
                            .background(FormGreen.fieldBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("This becomes a rule you can toggle and edit like any other.")
                            .font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

private let bypassPurple = Color(hex: "7C3AED")

private struct TaskRowView: View {
    var task: ChildTask
    var onOpen: () -> Void
    var onApprove: () -> Void
    var onRedo: () -> Void

    // dueLabel is stored as "Today, 1:00 PM" / "Yesterday, 5:00 PM" — the row
    // only has room for a quick glance, and task.state's own pill (Pending,
    // Overdue, …) already says whether it's on-time, so the day word here is
    // redundant. Just the clock time is enough.
    private func timeOnly(_ label: String) -> String {
        label.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
    }

    // Each task is its own floating card (ported 1:1 from the real app's
    // Components/TaskRow.swift) — not rows sharing one card with dividers.
    private var cardBackground: Color {
        switch task.state {
        case .review: return Color(hex: "FFF9ED")
        case .overdue: return Color(hex: "FFF5F3")
        case .bypass: return Color(hex: "F7F2FF")
        default: return EColor.surfaceContainerLowest
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 14) {
                mainRow
                if task.state == .review {
                    actionRow(primary: "APPROVE", primaryColor: Brand.greenDeep, primaryAction: onApprove, secondary: "REQUEST REDO", secondaryAction: onRedo)
                }
                if task.state == .bypass {
                    actionRow(primary: "ALLOW", primaryColor: bypassPurple, primaryAction: onApprove, secondary: "DENY", secondaryAction: onRedo)
                }
            }
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
            pill("Needs review", fg: Color(hex: "B26A00"), bg: Color(hex: "FFF3E0"))
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

    private func actionRow(primary: String, primaryColor: Color, primaryAction: @escaping () -> Void, secondary: String, secondaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: primaryAction) {
                Text(primary)
                    .font(Typography.font(12, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(primaryColor))
                    .shadow(color: primaryColor.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button(action: secondaryAction) {
                Text(secondary)
                    .font(Typography.font(12, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Color(hex: "B26A00"))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: "EF6C00"), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
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
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "EF6C00"))
                Image(systemName: EIcon.sf("photo_camera")).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
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

    init(child: Child, onCreate: @escaping (ChildTask) -> Void, onCancel: @escaping () -> Void) {
        self.child = child
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(title: "New task", onCancel: onCancel, onSave: {
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            onCreate(ChildTask(
                id: 0, title: title, state: .pending, category: category,
                description: description, note: nil, submittedAt: nil,
                dueLabel: hasDueDate ? formatted(dueDate) : nil, photoCount: 0,
                repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
            ))
        }, canSave: canSave, saveLabel: "Create task") {
            FormField(label: "Task name") {
                FormTextField(placeholder: "e.g. Make your bed", text: $title)
            }
            FormDateTimeRow(date: $dueDate, hasDate: $hasDueDate)
            RepeatPicker(selectedDays: $repeatDays)
            MoreOptions {
                FormField(label: "What to do") {
                    TextField("Instructions for the student…", text: $description, axis: .vertical)
                        .font(Typography.font(15, weight: .regular))
                        .lineLimit(3...5)
                        .padding(14)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f.string(from: date)
    }
}

