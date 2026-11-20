import SwiftUI

// The fourth tab: the child's profile (Settings is behind its gear). The
// child's controls as one short list (daily limit, downtime, blocked apps,
// adding tasks from templates), then their Lessons (photos they sent in for
// approved tasks) and Milestones (goals reached). The child is the one Home shows; with more than one, the
// avatars at the top switch it, for both tabs.
struct ScreenChildProfile: View {
    var onSwitchMode: () -> Void
    var onSignOut: (() -> Void)? = nil

    @Environment(SessionManager.self) private var session
    @State private var showSettings = ["settings", "childpaywall", "account", "edit", "accesscode"].contains(DemoMode.parentOpen ?? "")

    private var child: Child? {
        FamilyStore.children.first { $0.id == session.activeChildId } ?? FamilyStore.children.first
    }

    var body: some View {
        let _ = SyncState.shared.version
        Group {
            if let child {
                ChildProfilePage(child: child, onSettings: { showSettings = true })
                    .id(child.id)
            } else {
                VStack(spacing: 0) {
                    header(title: "Profile")
                    Text("Add a child in Settings to see their profile here.")
                        .font(Typography.font(15, weight: .regular))
                        .foregroundStyle(Neutral.secondary)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
                .background(EColor.surface)
            }
        }
        // Demo: `noahprofile` shows Noah's page (his trial's days left).
        .task {
            guard DemoMode.parentOpen == "noahprofile", let id = DemoMode.trialEndingChildId else { return }
            session.activeChildId = id
        }
        .sheet(isPresented: $showSettings) {
            ScreenSettings(onSwitchMode: onSwitchMode, onSignOut: onSignOut)
                .presentationDragIndicator(.visible)
        }
    }

    private func header(title: String) -> some View {
        HStack {
            Text(title)
                .font(Typography.font(32, weight: .heavy))
                .foregroundStyle(Neutral.ink)
            Spacer()
            settingsButton { showSettings = true }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

private func settingsButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "gearshape")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Neutral.ink)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Settings")
}

private enum ProfileTint {
    static let time = Color(hex: "1FA971")
    static let timeBg = Color(light: "EAF7EF", dark: "17301F")
    static let block = Color(hex: "E5484D")
    static let blockBg = Color(light: "FDEEEE", dark: "3A1E1E")
    static let night = downtimeIndigo
    static let nightBg = Color(light: "EFEFFC", dark: "22223A")
    static let tasks = Color(hex: "2F80ED")
}

private struct ChildProfilePage: View {
    @ObservedObject var child: Child
    var onSettings: () -> Void

    @Environment(SessionManager.self) private var session
    @ObservedObject private var goalStore = GoalStore.shared
    @ObservedObject private var trustStore = UnlockTrustStore.shared
    @State private var showUnlockGuide = DemoMode.parentOpen == "unlockguide"
    /// The ? pulses until it's been opened once.
    @AppStorage("evlin.unlockGuideSeen") private var unlockGuideSeen = false
    /// Milestones past the latest few are folded away until asked for.
    @State private var allMilestones = false
    @State private var openMilestone: Goal?
    /// A child on the free plan's far side (the Demo's Leo): the plan page.
    @State private var proChild: Child?
    @ObservedObject private var billing = BillingState.shared
    @State private var showPlan = false

    var body: some View {
        let _ = SyncState.shared.version
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The children's avatars on the left, the settings gear on
                // the right (2026-11-17, the user's call: the gear in place
                // of the parent's avatar and name; the account and Upgrade
                // live inside Settings, at its head).
                // Upgrade, full width with its words glowing, as in Settings
                // (2026-11-17, the user's call: "move the upgrade button
                // somewhere else"; a glowing pill beside the name, crowding
                // the line, before). Gone on Pro. With one child there are no
                // avatars, so it sits on the gear's line, beside it (the
                // user's call: "if it's a single child try to fit it"); with
                // more, under the avatars.
                let upgrade = EvlinPlan.offered && !billing.isPlus
                let manyChildren = FamilyStore.children.count > 1
                HStack(spacing: 6) {
                    if manyChildren { kidChips.fixedSize() }
                    if upgrade && !manyChildren {
                        UpgradeWideButton { showPlan = true }
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    settingsButton(onSettings)
                        .padding(.trailing, -10)
                }
                if upgrade && manyChildren {
                    UpgradeWideButton { showPlan = true }
                        .padding(.top, 10)
                        .transition(.opacity)
                }
                sectionHead("\(child.name)’s screen time")
                // Instant unlock waits for its server side (ServerSupport).
                // The screen time access code is in Settings (2026-11-19, the
                // user's call: parents won't use it much).
                if ServerSupport.instantUnlock {
                    ScreenTimeControls(child: child) { instantUnlockRow }
                } else {
                    ScreenTimeControls(child: child)
                }

                // Habits (and Lessons before them) were removed here at the
                // user's request (2026-11-05): just the goals reached.
                sectionHead("Completed milestones")
                    .padding(.top, 10)
                milestonesGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 40)
            .parentContentColumn(680)
        }
        .background(EColor.surface)
        .sensoryFeedback(.selection, trigger: allMilestones)
        // The Demo's free-plan example (Leo): his page, with the
        // trial-ended card over it, then the plan page.
        .childTrialEnded($proChild) { c in
            withAnimation(.snappy(duration: 0.3)) { session.activeChildId = c.id }
        }
        .sheet(isPresented: $showPlan) {
            EvlinPlanSheet()
                .presentationDragIndicator(.visible)
        }
        // Demo: `milestone` opens the newest completed milestone.
        .task {
            guard DemoMode.parentOpen == "milestone" else { return }
            try? await Task.sleep(for: .seconds(0.6))
            openMilestone = GoalStore.shared.milestones(for: child.id).first
        }
        .sheet(item: $openMilestone) { goal in
            MilestoneSheet(goal: goal, childName: child.name)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - The children

    /// The children as Home shows them, top right: two letters on a tint of
    /// their colour, the one showing a little larger with a ring, the
    /// others faded back. Tap one to switch.
    private var kidChips: some View {
        HStack(spacing: 4) {
            ForEach(FamilyStore.children, id: \.id) { c in
                let on = c.id == child.id
                Button {
                    if EvlinPlan.cardOnOpen( c.id) && !on { proChild = c }
                    withAnimation(.snappy(duration: 0.3)) { session.activeChildId = c.id }
                } label: {
                    Text(String(c.name.prefix(2)).uppercased())
                        .font(Typography.font(11, weight: .heavy))
                        .foregroundStyle(c.color)
                        .frame(width: 32, height: 32)
                        .background(c.color.opacity(0.14), in: Circle())
                        .overlay(Circle().strokeBorder(EColor.surface, lineWidth: 2))
                        .overlay(Circle().strokeBorder(on ? c.color : .clear, lineWidth: 2).padding(-2))
                        .scaleEffect(on ? 1.14 : 1)
                        .opacity(on ? 1 : 0.45)
                        .padding(2.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: - Screen time

    private func sectionHead(_ title: String) -> some View {
        Text(title)
            .font(Typography.font(20, weight: .semibold))
            .foregroundStyle(Neutral.ink)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }

    // Earned, not just switched on: until the child has done all their tasks
    // for 3 days in a row a pill stands where the switch will be, with the days
    // left, and opens the guide. Earned,
    // it's the parent's switch. Off again, the week starts over. On, work sent
    // in opens the phone; the parent can still review it after.
    private var instantUnlockRow: some View {
        let trust = trustStore.trust(for: child.id)
        let open = trust.earned || child.instantUnlock
        return HStack(spacing: 14) {
            Image(systemName: open ? "bolt.fill" : "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(open ? StatusCardStyle.green : Neutral.secondary.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Just the name, like the rows above it: the pill says how many
            // days are left (2026-11-09: "3 full days in a row" was removed).
            Text("Instant unlock")
                .font(Typography.font(16, weight: .medium))
                .foregroundStyle(Neutral.ink)
                .layoutPriority(1)
            Spacer(minLength: 8)
            // Earned, it's just the switch. Until then the days to go stand in
            // its place and open the guide, green with a ? until it's been read.
            if open {
                EToggle(on: Binding(get: { child.instantUnlock }, set: { setInstantUnlock($0) }),
                        color: StatusCardStyle.green)
                    .accessibilityLabel("Instant unlock")
            } else {
                let daysToGo = "\(trust.daysLeft) \(trust.daysLeft == 1 ? "day" : "days") to go"
                Button { showUnlockGuide = true; unlockGuideSeen = true } label: {
                    HStack(spacing: 5) {
                        Text(daysToGo)
                            .font(Typography.font(13, weight: .semibold))
                            .fixedSize()
                        if !unlockGuideSeen {
                            Image(systemName: "questionmark")
                                .font(.system(size: 11, weight: .heavy))
                        }
                    }
                    .foregroundStyle(unlockGuideSeen ? Neutral.secondary : .white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 31)
                    .background(unlockGuideSeen ? Color(light: "E9E9EA", dark: "353A42") : StatusCardStyle.green, in: Capsule())
                    // Until the guide's been read: the pill holds still and a
                    // soft halo ripples out from behind it (2026-11-09; the
                    // pill scaling itself made its words wobble).
                    .background { if !unlockGuideSeen { PillHalo(color: StatusCardStyle.green) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What Instant unlock does, \(daysToGo)")
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .sheet(isPresented: $showUnlockGuide) {
            InstantUnlockGuide(child: child, onTurnOn: { setInstantUnlock(true) })
                .presentationDragIndicator(.visible)
        }
    }

    private func setInstantUnlock(_ on: Bool) {
        child.instantUnlock = on
        child.saveState(label: "Instant unlock")
        if !on { trustStore.revoke(childId: child.id) }
    }

    // MARK: - Milestones

    /// How many completed rings show before the rest fold away.
    private static let milestonesShown = 4

    // Completed habits as full rings, two across, newest first (2026-11-07):
    // the latest four, the rest behind "Show all N" at the bottom.
    @ViewBuilder private var milestonesGrid: some View {
        let done = goalStore.milestones(for: child.id)
        // None yet: just the heading, no line under it (2026-11-09: "When Mia
        // completes a habit, it shows here as a full ring." was removed).
        if !done.isEmpty {
            let shown = allMilestones ? done : Array(done.prefix(Self.milestonesShown))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2), spacing: 22) {
                ForEach(shown) { goal in
                    Button { openMilestone = goal } label: {
                        CompletedMilestoneRing(goal: goal, size: 120).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            .padding(.top, 6)
            if done.count > Self.milestonesShown {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { allMilestones.toggle() }
                } label: {
                    Text(allMilestones ? "Show fewer" : "Show all \(done.count)")
                        .font(Typography.font(14.5, weight: .semibold))
                        .foregroundStyle(Neutral.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }
}

// MARK: - Screen time controls

/// The child's screen-time settings as one grouped card: Daily limit,
/// Downtime and Blocked apps, each opening its editor, with Instant unlock
/// under them on Profile.
struct ScreenTimeControls<Extra: View>: View {
    @ObservedObject var child: Child
    private let hasExtra: Bool
    private let extra: () -> Extra

    init(child: Child, @ViewBuilder extra: @escaping () -> Extra) {
        self.child = child
        self.hasExtra = true
        self.extra = extra
    }

    @State private var editingLimit = false
    @State private var editingDowntime: ChildRule?
    @State private var showBlocked = false
    /// Nothing blocked: the row is "Block an app" and opens the picker itself.
    @State private var blockingApp = false
    /// A change just saved shows on its own row, not in words: the row
    /// glows green a moment, its icon gives a little bounce, the new value
    /// rolls in, and a success haptic (2026-11-08: a saved change with no
    /// sign felt like nothing happened; a "Daily limit: 1h 45m" banner was
    /// tried and wasn't the feeling).
    @State private var flashRow: String?
    @State private var rowPops: [String: Int] = [:]
    /// Apps blocked when Block an app opened, to name the new one.
    @State private var blockedBefore: Set<String> = []

    private var downtime: ChildRule? { child.rules.first { $0.kind == .downtime } }

    var body: some View {
        let _ = SyncState.shared.version
        card
            .sensoryFeedback(.success, trigger: rowPops.values.reduce(0, +))
            .sheet(isPresented: $editingLimit) {
                EditScreenTimeLimitSheet(
                    childName: child.name,
                    daily: child.dailyLimitMin,
                    weekly: child.weeklySchedule,
                    onSave: { daily, weekly in
                        child.saveScreenTimeLimit(daily: daily, weekly: weekly)
                        editingLimit = false
                        applied(row: "Daily limit")
                    },
                    onCancel: { editingLimit = false }
                )
                .presentationDragIndicator(.visible)   // held when there are changes (FormShell)
            }
            .sheet(item: $editingDowntime) { rule in
                EditRuleSheet(rule: rule, onSave: { updated in
                    child.saveRule(updated)
                    editingDowntime = nil
                    applied(row: "Downtime")
                }, onCancel: { editingDowntime = nil }, onDelete: {
                    editingDowntime = nil
                    child.deleteRule(rule)
                    applied(row: "Downtime")
                })
                .closesOnlyWithButton()
            }
            .sheet(isPresented: $showBlocked) {
                ProfileBlockedAppsSheet(child: child)
                    .presentationDragIndicator(.visible)
            }
            // Blocked: straight to the list it's now in, which shows it (a
            // "Roblox is blocked" banner first was unneeded, 2026-11-08).
            .sheet(isPresented: $blockingApp, onDismiss: {
                let now = ChildScreenTimeSheet.blockedApps(childId: child.id)
                guard now.contains(where: { !blockedBefore.contains($0.appName) }) else { return }
                showBlocked = true
            }) {
                AddBlockedAppsSheet(child: child) { blockingApp = false }
                    .presentationDragIndicator(.visible)
            }
    }

    /// The child's controls as one list: what each is set to, a tap to
    /// change it.
    private var card: some View {
        let week = ScreenTimeSchedule.minutes(daily: child.dailyLimitMin, weekly: child.weeklySchedule)
        let today = ScreenTimeSchedule.todayIndex
        let varies = Set(week).count > 1
        let blocked = ChildScreenTimeSheet.blockedApps(childId: child.id)
        let rule = downtime
        // Hours that differ by day: today's, as the limit says "today".
        let downtimeValue: String = rule.map { r in
            guard r.on else { return "Off" }
            let today = ScreenTimeSchedule.days[ScreenTimeSchedule.todayIndex]
            let varies = !r.downtimeHours.isEmpty || !(r.downtimeDays.isEmpty || r.downtimeDays.count == 7)
            guard r.downtimeRuns(on: today) else { return "Off today" }
            let span = r.downtimeSpan(on: today)
            return "\(shortClock(span.from)) – \(shortClock(span.to))" + (varies ? " today" : "")
        } ?? "Off"
        return VStack(spacing: 0) {
            controlRow("hourglass", ProfileTint.time, "Daily limit",
                       value: ScreenTimeSchedule.limitText(week[today]) + (varies ? " today" : "")) { editingLimit = true }
            rowLine
            controlRow("moon.fill", ProfileTint.night, "Downtime", value: downtimeValue) {
                editingDowntime = rule ?? Child.newDowntimeRule()
            }
            rowLine
            blockedRow(blocked)
            if hasExtra {
                rowLine
                extra()
            }
        }
        // Apple's own grouped list (the user's reference, System Settings):
        // a flat light grey card, #F7F7F7, no edge, #EBEBEB lines between rows.
        // A warm grey box, no box, and a silver gradient were tried.
        .padding(.horizontal, 14)
        .background(ProfileCard.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ProfileCard.edge, lineWidth: 1))
    }

    private var rowLine: some View {
        Rectangle().fill(ProfileCard.line).frame(height: 1).padding(.leading, 46)
    }

    private func controlRow(_ symbol: String, _ tint: Color, _ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                rowIcon(symbol, tint, key: title)
                Text(title)
                    .font(Typography.font(16, weight: .medium))
                    .foregroundStyle(Neutral.ink)
                Spacer(minLength: 8)
                Text(value)
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(flashRow == title ? StatusCardStyle.green : Neutral.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.tertiaryLabel)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .background(rowFlash(title))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// Nothing blocked: "Block an app", straight to the picker. Something
    /// blocked: "Blocked apps" and how many ("3 apps"), opening the list
    /// (the apps' icons and names were tried, 2026-11-07).
    private func blockedRow(_ apps: [CachedAppBlock]) -> some View {
        Button {
            if apps.isEmpty {
                blockedBefore = Set(apps.map(\.appName))
                blockingApp = true
            } else {
                showBlocked = true
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "nosign")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(ProfileTint.block, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if !apps.isEmpty {
                    Text("Blocked apps")
                        .font(Typography.font(16, weight: .medium))
                        .foregroundStyle(Neutral.ink)
                    Spacer(minLength: 8)
                    Text(apps.count == 1 ? "1 app" : "\(apps.count) apps")
                        .font(Typography.font(15, weight: .regular))
                        .foregroundStyle(Neutral.secondary)
                        .lineLimit(1)
                } else {
                    Text("Block an app")
                        .font(Typography.font(16, weight: .medium))
                        .foregroundStyle(Neutral.ink)
                    Spacer(minLength: 8)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.tertiaryLabel)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .background(rowFlash("Blocked apps"))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// A row just changed: a soft green behind it that fades.
    private func rowFlash(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(StatusCardStyle.green.opacity(flashRow == key ? 0.16 : 0))
            .padding(.horizontal, -8)
            .padding(.vertical, 3)
            .allowsHitTesting(false)
    }

    /// A row's change took: once the sheet has gone, its glow, its icon's
    /// bounce and the haptic.
    private func applied(row: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            rowPops[row, default: 0] += 1
            withAnimation(.easeOut(duration: 0.2)) { flashRow = row }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 0.7)) { if flashRow == row { flashRow = nil } }
            }
        }
    }

    /// The row's icon: a little bounce when its change has just been saved.
    private func rowIcon(_ symbol: String, _ tint: Color, key: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .keyframeAnimator(initialValue: 1.0, trigger: rowPops[key, default: 0]) { icon, scale in
                icon.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.22, duration: 0.18, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
            }
            .symbolEffect(.bounce, value: rowPops[key, default: 0])
    }

    /// "8 PM", or "8:30 PM" when it isn't on the hour.
    private func shortClock(_ date: Date) -> String {
        ChildRule.fmtClock(date).replacingOccurrences(of: ":00", with: "")
    }

}

extension ScreenTimeControls where Extra == EmptyView {
    init(child: Child) {
        self.child = child
        self.hasExtra = false
        self.extra = { EmptyView() }
    }
}

/// A completed milestone opened: its picture, what it was, and when. No
/// prize (2026-11-17, the user's call: the habit is what matters).
private struct MilestoneSheet: View {
    var goal: Goal
    var childName: String

    var body: some View {
        VStack(spacing: 0) {
            CompletedMilestoneRing(goal: goal, size: 120, showsDate: false)
                .padding(.top, 34)
            if let at = goal.finishedAt {
                Text("\(childName) completed it on \(at.formatted(.dateTime.month(.wide).day()))")
                    .font(Typography.font(14, weight: .semibold))
                    .foregroundStyle(Neutral.secondary)
                    .padding(.top, 14)
            }
            if let picture = MilestoneShareCard.image(goal: goal, childName: childName) {
                ShareLink(item: picture,
                          preview: SharePreview("\(childName) completed \(goal.title)", image: picture)) {
                    // Big and easy to hit (2026-11-17, the user's call; a
                    // 40pt pill before).
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(Typography.font(18, weight: .semibold))
                        .foregroundStyle(Neutral.ink)
                        .frame(maxWidth: 320)
                        .frame(height: 56)
                        .background(EColor.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Neutral.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .padding(.top, 22)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
    }
}

// MARK: - Blocked apps

/// The child's blocked apps, each opening its own page (why, until when,
/// Lift), and Block an app.
private struct ProfileBlockedAppsSheet: View {
    @ObservedObject var child: Child
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        let _ = SyncState.shared.version
        let apps = ChildScreenTimeSheet.blockedApps(childId: child.id)
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    SheetCloseButton { dismiss() }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                Text("Blocked apps")
                    .font(Typography.font(26, weight: .heavy))
                    .foregroundStyle(Neutral.ink)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                ScrollView {
                    VStack(spacing: 14) {
                        Button { adding = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Neutral.navy, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text("Block an app")
                                    .font(Typography.font(16.5, weight: .bold))
                                    .foregroundStyle(Neutral.ink)
                                Spacer()
                            }
                            .padding(16)
                            .background(Neutral.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(CardPressStyle())

                        if apps.isEmpty {
                            Text("Nothing is blocked. Block an app for a set time, the rest of today, or until you allow it again.")
                                .font(Typography.font(14.5, weight: .regular))
                                .foregroundStyle(Neutral.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(apps.enumerated()), id: \.element.id) { i, block in
                                    if i > 0 { Divider().padding(.leading, 56) }
                                    BlockedAppRow(block: block)
                                }
                            }
                            .background(FormGreen.fieldBg)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(EColor.surface)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { blockId in
                BlockedAppDetail(blockId: blockId, child: child)
            }
        }
        .sheet(isPresented: $adding) {
            AddBlockedAppsSheet(child: child) { adding = false }
                .presentationDragIndicator(.visible)   // held once apps are picked (FormShell)
        }
    }
}

// MARK: - Task templates

/// A ready-made chore: its name, how often it comes back, why it suits the
/// child, the ages it fits, and its picture.
struct TaskTemplate: Identifiable, Hashable {
    var id: String { title }
    var title: String
    /// The task's recurrence code ("daily", "mon,tue,wed,thu,fri", "none").
    var recurrence: String
    var why: String = ""
    var ages: ClosedRange<Int> = 3...13
    var symbol: String
    var colors: [Color]
    var kind: TaskKind = .home

    var repeatText: String {
        switch recurrence {
        case "daily": return "Every day"
        case "mon,tue,wed,thu,fri": return "Weekdays"
        case "sat,sun": return "Weekends"
        case "none": return "Just once"
        default: return recurrence.split(separator: ",").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
        }
    }

    private static func g(_ a: String, _ b: String) -> [Color] { [Color(hex: a), Color(hex: b)] }

    /// The chore list (the user's master list, 2026-11-05): seven household
    /// jobs, for every age, and nothing else. Reading moved to Learning
    /// habits. `why` is what the job involves; picking one fills the task's
    /// What to do with it.
    static let all: [TaskTemplate] = [
        .init(title: "Clean your room", recurrence: "daily", why: "Make the bed, pick up floor items, and put toys away.",
              ages: 3...17, symbol: "bed.double.fill", colors: g("14B8A6", "0EA5E9")),
        .init(title: "Do your homework", recurrence: "mon,tue,wed,thu,fri", why: "Complete the day's school assignments and pack the bag.",
              ages: 3...17, symbol: "pencil", colors: g("2563EB", "14B8A6")),
        .init(title: "Water the plants", recurrence: "wed,sat", why: "Check soil and water indoor or patio plants.",
              ages: 3...17, symbol: "leaf.fill", colors: g("16A34A", "0EA5E9")),
        .init(title: "Help with laundry", recurrence: "sat", why: "Sort clothes, load the washer, or fold clean clothes.",
              ages: 3...17, symbol: "basket.fill", colors: g("6366F1", "0EA5E9")),
        .init(title: "Set or clear the table", recurrence: "daily", why: "Bring plates and cutlery before meals, or wipe down after.",
              ages: 3...17, symbol: "fork.knife", colors: g("F59E0B", "EF4444")),
        .init(title: "Take care of the pet", recurrence: "daily", why: "Feed, refresh the water bowl, or take them on a walk.",
              ages: 3...17, symbol: "pawprint.fill", colors: g("F97316", "F59E0B")),
        .init(title: "Take out the trash", recurrence: "mon,thu", why: "Empty the bedroom and kitchen bins into the main bin.",
              ages: 3...17, symbol: "trash.fill", colors: g("64748B", "0EA5E9")),
    ]

    static func named(_ title: String) -> TaskTemplate? { all.first { $0.title == title } }

    /// The chores that suit `age` (all of them, as the list stands).
    static func picks(age: Int) -> [TaskTemplate] {
        let fit = all.filter { $0.ages.contains(age) }
        return fit.count >= 3 ? fit : all
    }

    /// The ideas of one kind that suit `age`.
    static func picks(age: Int, in kind: TaskKind) -> [TaskTemplate] {
        all.filter { $0.kind == kind && $0.ages.contains(age) }
    }
}

/// The kinds of task across the top of New task.
enum TaskKind: String, CaseIterable, Identifiable {
    case me = "Me", school = "School", home = "Home"
    case care = "Pets & plants", active = "Active", creative = "Creative"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .me: return "sun.max.fill"
        case .school: return "book.fill"
        case .home: return "house.fill"
        case .care: return "pawprint.fill"
        case .active: return "figure.run"
        case .creative: return "paintpalette.fill"
        }
    }
}

/// A few templates that go together.
struct TaskRoutine: Identifiable {
    var id: String { name }
    var name: String
    var why: String
    var tasks: [String]
    var symbol: String
    var colors: [Color]

    static let all: [TaskRoutine] = [
        .init(name: "Calmer mornings", why: "Out the door without reminders", tasks: ["Make the bed", "Brush teeth", "Pack the school bag"],
              symbol: "sunrise.fill", colors: [Color(hex: "F59E0B"), Color(hex: "EF4444")]),
        .init(name: "Homework before screens", why: "Schoolwork first, then apps", tasks: ["Homework", "Read for 20 minutes"],
              symbol: "pencil.and.list.clipboard", colors: [Color(hex: "6366F1"), Color(hex: "A855F7")]),
        .init(name: "A helping hand", why: "Small jobs for the family", tasks: ["Set the table", "Feed the pet", "Put toys away"],
              symbol: "hands.sparkles.fill", colors: [Color(hex: "14B8A6"), Color(hex: "0EA5E9")]),
    ]
}

/// Adding chores on a black cover of choices: type your own, or take the
/// top three picked for the child's age (colour cards) and Shuffle for
/// three more, with routines under them. Chores go on one day only (they don't repeat): pick
/// a day of the coming week, pick its chores, move to another day and pick
/// again, then add them all at once. That's planning the week. What's picked
/// for the day shows in a preview of the child's own list. (Home's + still
/// opens the full Add Task form, for repeats and times.)
struct TaskTemplatesSheet: View {
    @ObservedObject var child: Child
    @Environment(\.dismiss) private var dismiss

    @State private var day: Date
    /// What's picked, per day.
    @State private var plan: [Date: [String]] = [:]
    @State private var custom: [TaskTemplate] = []
    @State private var typed = ""
    @State private var shuffle = 0
    @State private var pickTick = 0
    @State private var addedTick = 0
    @FocusState private var typing: Bool

    init(child: Child, startDay: Date = Date()) {
        self.child = child
        _day = State(initialValue: Calendar.current.startOfDay(for: startDay))
    }

    private static let cal = Calendar.current
    private var days: [Date] {
        let today = Self.cal.startOfDay(for: Date())
        return (0..<7).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    }

    /// The picks for the day showing.
    private var picked: [String] {
        get { plan[day] ?? [] }
    }
    private func setPicked(_ titles: [String]) { plan[day] = titles }
    private var pickedCount: Int { plan.values.reduce(0) { $0 + $1.count } }
    private var plannedDays: Int { plan.values.filter { !$0.isEmpty }.count }

    private var dayName: String {
        let today = Self.cal.startOfDay(for: Date())
        if Self.cal.isDate(day, inSameDayAs: today) { return "today" }
        if let t = Self.cal.date(byAdding: .day, value: 1, to: today), Self.cal.isDate(day, inSameDayAs: t) { return "tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    private var onDay: Set<String> {
        Set(plannedTasks(childId: child.id, on: day).map { $0.title.lowercased() })
    }

    /// The child's age's picks not on the day's list yet, three at a time.
    private var three: [TaskTemplate] {
        let have = onDay
        let list = TaskTemplate.picks(age: child.age).filter { !have.contains($0.title.lowercased()) }
        guard !list.isEmpty else { return [] }
        let start = (shuffle * 3) % list.count
        return (0..<min(3, list.count)).map { list[(start + $0) % list.count] }
    }

    private func template(_ title: String) -> TaskTemplate? {
        custom.first { $0.title == title } ?? TaskTemplate.named(title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(child.name.uppercased())'S \(dayName.uppercased())")
                        .font(Typography.font(12, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(GoalStyle.soft)
                    Text("What should \(child.name) do?")
                        .font(Typography.font(28, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    dayPicker
                        .padding(.top, 14)

                    ChorePreview(childName: child.name, dayName: dayName,
                                 chores: picked.compactMap(template),
                                 onRemove: { title in pickTick += 1; setPicked(picked.filter { $0 != title }) })
                        .padding(.top, 16)

                    typeField
                        .padding(.top, 16)

                    HStack(alignment: .firstTextBaseline) {
                        (Text("Top 3 for \(child.name) ").foregroundStyle(.white)
                         + Text("· age \(child.age)").foregroundStyle(GoalStyle.soft))
                            .font(Typography.font(15, weight: .bold))
                        Spacer()
                        darkShuffleButton(shuffle) {
                            withAnimation(.spring(duration: 0.4, bounce: 0.15)) { shuffle += 1 }
                            pickTick += 1
                        }
                    }
                    .padding(.top, 24)

                    VStack(spacing: 12) {
                        ForEach(Array(three.enumerated()), id: \.element.id) { i, t in
                            choreCard(t, index: i)
                        }
                    }
                    .id(shuffle)
                    .padding(.top, 14)

                    Text("Routines")
                        .font(Typography.font(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 24)
                        .padding(.bottom, 10)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(TaskRoutine.all) { routineCard($0) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -20)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            addButton
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .background(GoalStyle.ground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: pickTick)
        .sensoryFeedback(.success, trigger: addedTick)
        .animation(.snappy(duration: 0.25), value: plan)
    }

    /// The coming seven days; a dot under any day that has picks waiting.
    private var dayPicker: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { d in
                let on = Self.cal.isDate(d, inSameDayAs: day)
                let count = plan[d]?.count ?? 0
                Button { withAnimation(.snappy(duration: 0.25)) { day = d }; pickTick += 1 } label: {
                    VStack(spacing: 3) {
                        Text(Self.cal.isDate(d, inSameDayAs: days[0]) ? "Today" : d.formatted(.dateTime.weekday(.abbreviated)))
                            .font(Typography.font(11.5, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(Self.cal.component(.day, from: d))")
                            .font(Typography.font(15, weight: .heavy))
                            .monospacedDigit()
                        Circle()
                            .fill(on ? Color.black : Color(hex: "34C759"))
                            .frame(width: 5, height: 5)
                            .opacity(count > 0 ? 1 : 0)
                    }
                    .foregroundStyle(on ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).day()) + (count > 0 ? ", \(count) picked" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(GoalStyle.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var typeField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(GoalStyle.soft)
            TextField("", text: $typed, prompt: Text("Type a chore").foregroundStyle(Color.white.opacity(0.35)))
                .font(Typography.font(16, weight: .medium))
                .foregroundStyle(.white)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit(addTyped)
            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", action: addTyped)
                    .font(Typography.font(15, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(GoalStyle.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(GoalStyle.hairline))
    }

    private func addTyped() {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        if template(t) == nil {
            custom.insert(TaskTemplate(title: t, recurrence: "none", symbol: "checkmark",
                                       colors: [Color(hex: "475569"), Color(hex: "1E293B")]), at: 0)
        }
        if !picked.contains(t) { setPicked(picked + [t]) }
        pickTick += 1
        typed = ""
    }

    /// A pick as a colour card on the black: its icon, name, why it helps,
    /// the ages it suits. Tap to put it in the preview, again to take it out.
    private func choreCard(_ t: TaskTemplate, index: Int) -> some View {
        let on = picked.contains(t.title)
        return ChoiceCard(symbol: t.symbol, title: t.title, why: t.why,
                          tag: "Ages \(t.ages.lowerBound)–\(t.ages.upperBound)",
                          colors: t.colors, picked: on, index: index) {
            pickTick += 1
            setPicked(on ? picked.filter { $0 != t.title } : picked + [t.title])
        }
    }

    private func routineCard(_ routine: TaskRoutine) -> some View {
        let open = routine.tasks.filter { !onDay.contains($0.lowercased()) }
        let all = !open.isEmpty && open.allSatisfy(picked.contains)
        return Button {
            pickTick += 1
            if all { setPicked(picked.filter { !open.contains($0) }) }
            else { setPicked(picked + open.filter { !picked.contains($0) }) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: routine.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LinearGradient(colors: routine.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    Image(systemName: all ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(all ? .white : GoalStyle.soft)
                }
                Spacer(minLength: 8)
                Text(routine.name)
                    .font(Typography.font(15.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(open.isEmpty ? "Already on the list" : routine.tasks.joined(separator: ", "))
                    .font(Typography.font(12.5, weight: .regular))
                    .foregroundStyle(GoalStyle.soft)
                    .lineLimit(2)
            }
            .padding(14)
            .frame(width: 200, height: 140, alignment: .topLeading)
            .background(GoalStyle.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(all ? Color.white : GoalStyle.hairline, lineWidth: all ? 1.5 : 1))
            .opacity(open.isEmpty ? 0.5 : 1)
        }
        .buttonStyle(CardPressStyle())
        .disabled(open.isEmpty)
        .accessibilityLabel("\(routine.name): \(routine.tasks.joined(separator: ", "))")
        .accessibilityAddTraits(all ? .isSelected : [])
    }

    private var addButton: some View {
        let n = pickedCount
        let label = plannedDays > 1 ? "Add \(n) chores to \(plannedDays) days"
            : "Add to \(child.name)'s \(plan.first(where: { !$0.value.isEmpty }).map { dayLabel($0.key) } ?? dayName)"
        return Button(action: addPicked) {
            HStack(spacing: 10) {
                if n > 0 {
                    Text("\(n)")
                        .font(Typography.font(14, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.black, in: Circle())
                        .contentTransition(.numericText(value: Double(n)))
                }
                Text(n > 0 ? label : "Pick a chore to add it")
            }
            .font(Typography.font(17, weight: .heavy))
            .foregroundStyle(n > 0 ? .black : GoalStyle.soft)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(n > 0 ? Color.white : GoalStyle.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(n == 0)
    }

    private func dayLabel(_ d: Date) -> String {
        let today = Self.cal.startOfDay(for: Date())
        if Self.cal.isDate(d, inSameDayAs: today) { return "today" }
        if let t = Self.cal.date(byAdding: .day, value: 1, to: today), Self.cal.isDate(d, inSameDayAs: t) { return "tomorrow" }
        return d.formatted(.dateTime.weekday(.wide))
    }

    private func addPicked() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        // Each chore on its own day only: no repeat.
        let chosen: [(String, TaskTemplate)] = plan.sorted { $0.key < $1.key }.flatMap { d, titles in
            titles.compactMap(template).map { (f.string(from: d), $0) }
        }
        addedTick += 1
        dismiss()
        // Saved as the sheet slides away, so the rows land on Home then.
        // The same create as every task (TaskEdits.create).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.snappy(duration: 0.3)) {
                for (dayKey, t) in chosen {
                    _ = TaskEdits.create(childId: child.id, title: t.title, instructions: nil, recurrence: "none",
                                         category: "Chore", dueTime: nil, dueDate: dayKey)
                }
            }
        }
    }
}

/// What the child will see, live as chores are picked: their list with each
/// chore's emoji, and that the phone opens once it's done. Tap a row to
/// take it out.
private struct ChorePreview: View {
    var childName: String
    var dayName: String
    var chores: [TaskTemplate]
    var onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What \(childName) will see \(dayName == "today" || dayName == "tomorrow" ? dayName : "on " + dayName)")
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(Neutral.secondary)
                Spacer()
                Text("\(chores.count) chore\(chores.count == 1 ? "" : "s")")
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(Neutral.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 6)
            if chores.isEmpty {
                Text("Pick chores below and they show up here.")
                    .font(Typography.font(14.5, weight: .regular))
                    .foregroundStyle(Neutral.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(chores.enumerated()), id: \.element.id) { i, chore in
                    Button { onRemove(chore.title) } label: {
                        HStack(spacing: 12) {
                            Text(EmojiSuggest.best(for: chore.title))
                                .font(.system(size: 19))
                                .frame(width: 34, height: 34)
                                .background(Neutral.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(chore.title)
                                .font(Typography.font(15, weight: .semibold))
                                .foregroundStyle(Neutral.ink)
                            Spacer()
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Neutral.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(chore.title)")
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Apps open when these are done")
                        .font(Typography.font(12.5, weight: .medium))
                }
                .foregroundStyle(Neutral.secondary)
                .padding(.top, 8)
            }
        }
        .padding(14)
        .background(EColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Light inside, as on the child's own screen, on the picker's black.
        .environment(\.colorScheme, .light)
    }
}

/// The screen-time card's colours: Apple's grouped list.
enum ProfileCard {
    // The page's Alabaster with a warm edge, never lighter (2026-11-14,
    // the user's call: Apple's #F7F7F7, then the cream #F7F5F0, read as
    // white on the warm page).
    // Since 2026-11-14 (the user's call), its own soft fill a step under
    // the page, no edge, as Apple's grouped list sits on its page: the
    // page's own colour with an edge read as no card at all.
    static let fill = Color(light: "F2F2F7", dark: "262A30")
    static let edge = Color.clear
    static let line = Color(light: "E5E5EA", dark: "353A42")
}


/// Rings that ripple out from a pill's edge and fade, one after another,
/// then a rest: "tap me" without moving the pill or its words. Each starts
/// unseen at the edge, so nothing outlines the pill between ripples.
private struct PillHalo: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            ZStack {
                ring(delay: 0)
                ring(delay: 0.45)
            }
            .allowsHitTesting(false)
        }
    }

    private func ring(delay: Double) -> some View {
        Capsule()
            .stroke(color, lineWidth: 1.5)
            .keyframeAnimator(initialValue: Ripple(), repeating: true) { view, r in
                view.padding(-r.grow).opacity(r.alpha)
            } keyframes: { _ in
                KeyframeTrack(\.grow) {
                    LinearKeyframe(0, duration: delay)
                    CubicKeyframe(11, duration: 1.6)
                    LinearKeyframe(11, duration: 1.4 - delay)
                }
                KeyframeTrack(\.alpha) {
                    LinearKeyframe(0, duration: delay)
                    LinearKeyframe(0.7, duration: 0.15)
                    CubicKeyframe(0, duration: 1.45)
                    LinearKeyframe(0, duration: 1.4 - delay)
                }
            }
    }

    private struct Ripple {
        var grow: CGFloat = 0
        var alpha: Double = 0
    }
}
