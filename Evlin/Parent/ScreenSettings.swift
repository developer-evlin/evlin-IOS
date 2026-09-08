import SwiftUI

// Exact structural port of the real app's HomeSettingsSheet.swift: same
// Form/Section grouped-list layout, same row anatomy (icon chip + title +
// subtitle + value/chevron), same SF Symbol icons, same section order and
// copy. Every APIClient/FamilyStore network round-trip is replaced with
// local @State / the shared FamilyStore mock — this is a local-only
// prototype, nothing here persists past a relaunch unless noted. Sections
// that exist in HomeSettingsSheet's state machine but aren't reachable from
// any row in production (Locked Apps & Lists, AI Behavior / Smart Mode,
// Memory, Replay tours) are intentionally omitted to match what's actually
// visible in the real app today.
enum SettingsRoute: Hashable {
    case parentProfile
    case signOut
    case privacyTerms
    case billing
}

struct ScreenSettings: View {
    var onSwitchMode: () -> Void
    @State private var path = NavigationPath()
    @State private var openChildId: String?

    // Root notification toggle — mirrors the source's `notifyPushEnabled`.
    // Nothing else to configure — this is the only notification setting.
    @State private var pushOn = true

    // Parent profile — source's parentName/selectedParentAccentHex.
    @State private var parentName = "Alex Carter"
    @State private var selectedAccentHex = SettingsPresentation.accentHexOptions[0]

    // Add child — source's `showAddChildPairing`. No real pairing flow exists
    // here (no FamilyControls/device pairing), so this is a name/age form
    // that closes without touching `FamilyStore.children` (that list is a
    // shared static mock read by several other screens).
    @State private var showAddChild = false
    @State private var showDeleteAccountConfirm = false
    // No @Published/ObservableObject wiring on FamilyStore (it's a static
    // mock namespace) — bumping this after a mutation is what makes
    // SwiftUI re-evaluate body and pick up the change, same trick used
    // elsewhere in this file for local-only mock state.
    @State private var familyRefreshTick = 0
    @State private var childPendingRemoval: Child?
    @State private var editingChild: Child?

    // Billing — no equivalent in HomeSettingsSheet to port (the real app has
    // no StoreKit integration wired into settings yet), so this is built
    // fresh rather than ported: mocked plan/cycle state, Task.sleep-based
    // fake upgrade, matching this file's established local-only mocking.
    // Shared (BillingState.shared, not local @State) so ScreenProfile's
    // plan row reflects whatever's actually set here.
    @ObservedObject private var billing = BillingState.shared
    @State private var isProcessingUpgrade = false
    @State private var showCancelConfirm = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                settingsRootContent
            }
            .background(EColor.surfaceContainerLowest)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .parentProfile: parentProfilePage
                case .signOut: signOutPage
                case .privacyTerms: privacyTermsPage
                case .billing: billingPage
                }
            }
        }
        .fullScreenCover(item: Binding(get: { openChildId.map { IdentifiedString(value: $0) } }, set: { openChildId = $0?.value })) { wrapped in
            NavigationStack { ScreenProfile(childId: wrapped.value, onBack: { openChildId = nil }) }
        }
        .sheet(isPresented: $showAddChild) {
            SettingsAddChildSheet(
                onAdd: { name, age in
                    FamilyStore.children.append(Child(
                        id: UUID().uuidString, name: name, age: age, dailyLimitMin: 60,
                        color: FamilyStore.nextChildColor(), status: .unlocked,
                        timeLeft: "1h 0m", timePct: 100, usageTodayMin: 0,
                        tasksDone: 0, tasksTotal: 0, subtitle: "No tasks yet"
                    ))
                    familyRefreshTick += 1
                    showAddChild = false
                },
                onCancel: { showAddChild = false }
            )
        }
        // Used to live on the (now-removed) "Children and devices" list
        // page, reachable there by swipe — the root Family rows are plain
        // VStack rows, not a List, so swipeActions has no host here. A
        // long-press context menu is the nearest equivalent that doesn't
        // require rebuilding the section as a List.
        .sheet(item: $editingChild) { child in
            EditChildProfileSheet(
                child: child,
                onSave: { name, age, avatar in
                    child.name = name
                    child.age = age
                    child.avatar = avatar
                    familyRefreshTick += 1
                    editingChild = nil
                },
                onCancel: { editingChild = nil }
            )
        }
        .alert(
            "Remove \(childPendingRemoval?.name ?? "this child")'s profile?",
            isPresented: Binding(get: { childPendingRemoval != nil }, set: { if !$0 { childPendingRemoval = nil } })
        ) {
            Button("Cancel", role: .cancel) { childPendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let id = childPendingRemoval?.id {
                    FamilyStore.removeChild(id)
                    familyRefreshTick += 1
                }
                childPendingRemoval = nil
            }
        } message: {
            Text("This removes their profile, tasks, rules, and paired devices. This can't be undone.")
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Root
    //
    // Hand-built instead of Form/Section: single-line rows by default (no
    // subtitle unless the row would otherwise be ambiguous — none here
    // are), small uppercase labels sitting tight against the group they
    // name, and a light-grey card on a *white* page — Form's own
    // insetGrouped styling only gives the opposite (white cards on a grey
    // page), which is what a native Form/Section here would've produced
    // no matter how the colors were themed.
    @ViewBuilder
    private var settingsRootContent: some View {
        VStack(alignment: .leading, spacing: settingsGroupGap) {
            settingsAccountCard

            settingsGroup("FAMILY") {
                ForEach(FamilyStore.children) { child in
                    Button { openChildId = child.id } label: {
                        settingsFamilyChildRow(child)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { editingChild = child } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { childPendingRemoval = child } label: { Label("Remove", systemImage: "trash") }
                    }
                    settingsDivider
                }

                Button { showAddChild = true } label: {
                    addChildRow
                }
                .buttonStyle(.plain)
            }

            settingsGroup("ALERTS") {
                settingsCompactRow(icon: "bell", title: "Push notifications", showChevron: false) {
                    Toggle("", isOn: $pushOn).labelsHidden().tint(EColor.secondary)
                }

                settingsDivider

                NavigationLink(value: SettingsRoute.billing) {
                    settingsCompactRow(icon: "creditcard", title: "Billing and receipts")
                }
                .buttonStyle(.plain)
            }

            settingsGroup("SUPPORT") {
                // Honest about what this actually is — a mailbox, not a
                // help center — and the prefilled metadata is what turns
                // "it's not working" into something traceable.
                Button {
                    if let url = reportProblemURL { UIApplication.shared.open(url) }
                } label: {
                    settingsCompactRow(icon: "exclamationmark.bubble", title: "Report a problem")
                }
                .buttonStyle(.plain)

                settingsDivider

                // Not wired to anything yet, but still tappable in
                // principle — gets the same chevron as every other row
                // instead of being the odd one out.
                settingsCompactRow(icon: "sparkles", title: "Replay the tours")

                settingsDivider

                ShareLink(item: "I've been using Evlin to manage screen time for my kids — thought you might like it too.") {
                    settingsCompactRow(icon: "square.and.arrow.up", title: "Share Evlin")
                }
                .buttonStyle(.plain)
            }

            settingsFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // Avatar/name/subtitle is its own tap target into Parent Profile; the
    // lock note + Upgrade button below is a second, independent tap target
    // in the same card — nesting a Button inside the NavigationLink's own
    // label would break hit-testing, so they're siblings sharing one
    // background/clip instead of one row wrapping the other.
    private var settingsAccountCard: some View {
        let personColor = CalendarData.person("family").color
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: SettingsRoute.parentProfile) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(personColor)
                        .frame(width: 68, height: 68)
                        .overlay(Text(String(parentName.prefix(1))).font(Typography.font(26, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(parentName).font(Typography.font(19, weight: .bold)).foregroundStyle(EColor.onSurface)
                        Text("My Family · \(billing.isPlus ? "Pro" : "Free plan")")
                            .font(Typography.font(13, weight: .regular))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }
                    Spacer(minLength: 10)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(EColor.outline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Removed entirely once on Pro — nothing left to upsell.
            if !billing.isPlus {
                Divider().padding(.horizontal, 14)

                Text("Repeating tasks, downtime, and bedtime are locked on the free plan.")
                    .font(Typography.font(13, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                Button { path.append(SettingsRoute.billing) } label: {
                    Text("Upgrade to Pro")
                        .font(Typography.font(15, weight: .bold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
        .background(settingsCardFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // Same 32px-avatar/name/device-count/chevron row every child gets, but
    // solid-color-fill-plus-white-initial rather than the generic mint
    // InitialsAvatar — same reasoning as the parent avatar: matches Home's
    // per-child treatment instead of reading as a placeholder.
    private func settingsFamilyChildRow(_ child: Child) -> some View {
        HStack(spacing: 12) {
            if let avatar = child.avatar {
                Image(uiImage: avatar).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(Circle())
            } else {
                Circle().fill(child.color).frame(width: 32, height: 32)
                    .overlay(Text(String(child.name.prefix(1))).font(Typography.font(13, weight: .bold)).foregroundStyle(.white))
            }
            Text(child.name).font(Typography.font(15.5, weight: .regular)).foregroundStyle(EColor.onSurface)
            Spacer(minLength: 10)
            Text("\(child.devices.count) \(child.devices.count == 1 ? "device" : "devices")")
                .font(Typography.font(13, weight: .regular))
                .foregroundStyle(EColor.onSurfaceVariant)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(EColor.outline)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var addChildRow: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(EColor.primary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(EColor.primary))
            Text("Add a child").font(Typography.font(15.5, weight: .semibold)).foregroundStyle(EColor.primary)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // mailto: with the diagnostic context a beta parent's "it's not
    // working" report is otherwise missing — enough to cross-reference
    // against Sentry without asking them to dig up any of it themselves.
    // support@evlin.app is a placeholder inbox; swap for the real one.
    private var reportProblemURL: URL? {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        // Nothing in this prototype persists a real anonymous install/child
        // id — the first child's mock UUID stands in for one.
        let childId = FamilyStore.children.first?.id ?? "none"
        let body = """


        ---
        App version: \(appVersion) (\(buildNumber))
        iOS version: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        Child ID: \(childId)
        """
        var components = URLComponents(string: "mailto:support@evlin.app")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "Evlin bug report"),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // Small muted centered text, not rows — these are looked-at-once
    // legal/version info, not settings a parent configures.
    private var settingsFooter: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                NavigationLink(value: SettingsRoute.privacyTerms) {
                    Text("Privacy and terms")
                }
                .buttonStyle(.plain)
                Text("·")
                Text("Version \(appVersionString)")
            }
            .font(Typography.font(12, weight: .regular))
            .foregroundStyle(EColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var settingsDivider: some View {
        Divider().padding(.leading, 46)
    }

    // Settings-local card fill — lighter than the shared surfaceContainerHigh
    // token (which several other screens also use for chips/disabled states
    // that weren't part of this pass) so this change stays scoped to
    // Settings' own cards instead of shifting color everywhere that token
    // appears.
    private var settingsCardFill: Color { Color(hex: "F7F7F5") }

    // Total whitespace from one card's bottom edge to the next header's top
    // (outer spacing + the header's own line height) works out to ~22pt
    // once combined with settingsGroup's 6pt header-to-card gap below.
    private var settingsGroupGap: CGFloat { 3 }

    // The label sits right on top of its group (6pt) with the real
    // separation (settingsGroupGap, set by the outer VStack's own spacing)
    // coming *before* the label, not after — that's what makes it read as
    // "attached to the group below," not floating between two groups.
    private func settingsGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Typography.font(11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .background(settingsCardFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // One line — icon, title, an optional trailing value or control, and a
    // chevron only on rows that actually navigate or act. No subtitle slot
    // at all: the old two-line rows paid the same ~72pt height whether or
    // not there was a second line worth showing.
    private func settingsCompactRow<Trailing: View>(
        icon: String,
        title: String,
        value: String? = nil,
        showChevron: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                // Darker than the row's own secondary/value text
                // (onSurfaceVariant) — a thin glyph reads noticeably
                // lighter than solid text at the same color, so matching
                // hex values alone still left icons looking washed out.
                .foregroundStyle(EColor.onSurface)
                .frame(width: 22)
            Text(title).font(Typography.font(15.5, weight: .regular)).foregroundStyle(EColor.onSurface)
            Spacer(minLength: 10)
            if let value {
                Text(value).font(Typography.font(15, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
            }
            trailing()
            if showChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(EColor.outline)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: - Billing (net-new — see the state block above for why this
    // isn't a port like the rest of the file)

    private let plusFeatures = [
        "Unlimited custom rules & app-time limits",
        "AI-powered de-escalation strategies in chat",
        "Weekly behavior insights & trend reports",
        "Reflection review & approval tools",
        "Priority support",
    ]

    private var priceLabel: String { billing.billingCycle == .yearly ? "$79.99/yr" : "$9.99/mo" }

    private var billingPage: some View {
        Form {
            Section {
                planHeroCard
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            if !billing.isPlus {
                Section("What you get with Plus") {
                    ForEach(plusFeatures, id: \.self) { feature in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(EColor.secondary)
                            Text(feature)
                                .font(Typography.font(14, weight: .medium))
                                .foregroundStyle(EColor.onSurface)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("Billing Cycle") {
                    billingCyclePicker
                        .padding(.vertical, 4)
                }

                Section {
                    PrimaryButton(title: isProcessingUpgrade ? "Upgrading…" : "Upgrade to Plus — \(priceLabel)") {
                        Task { await upgrade() }
                    }
                    .disabled(isProcessingUpgrade)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    Button("Restore Purchases") {}
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Section("Manage") {
                    settingsRow(
                        title: "Plan",
                        subtitle: "Evlin Plus · \(billing.billingCycle == .yearly ? "Yearly" : "Monthly")",
                        systemImage: "sparkles",
                        value: priceLabel,
                        accent: EColor.primary
                    )

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        settingsRow(title: "Manage Subscription", subtitle: "Change plan or payment method in Settings", systemImage: "gearshape", accent: EColor.primary)
                    }

                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        settingsRow(title: "Cancel Subscription", subtitle: "You'll keep Plus until the period ends", systemImage: "xmark.circle", accent: EColor.danger, danger: true)
                    }
                }
            }
        }
        .navigationTitle("Evlin Plan")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Cancel Evlin Plus?", isPresented: $showCancelConfirm) {
            Button("Keep Plus", role: .cancel) {}
            Button("Cancel Subscription", role: .destructive) { billing.isPlus = false }
        } message: {
            Text("You'll lose unlimited rules, AI strategies, and insights at the end of the current billing period.")
        }
    }

    private var planHeroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(billing.isPlus ? EColor.primary : EColor.surfaceContainerHigh).frame(width: 64, height: 64)
                Image(systemName: billing.isPlus ? "sparkles" : "lock.open")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(billing.isPlus ? .white : EColor.onSurfaceVariant)
            }
            VStack(spacing: 4) {
                Text(billing.isPlus ? "You're on Evlin Plus" : "You're on the Free plan")
                    .font(Typography.font(17, weight: .bold))
                    .foregroundStyle(EColor.onSurface)
                Text(billing.isPlus ? "Thanks for supporting Evlin." : "Core screen-time controls for one child.")
                    .font(Typography.font(13, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(EColor.surfaceContainerLowest))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(EColor.outlineVariant.opacity(0.7), lineWidth: 1))
    }

    private var billingCyclePicker: some View {
        HStack(spacing: 10) {
            cycleOption(.monthly, title: "Monthly", price: "$9.99/mo", badge: nil)
            cycleOption(.yearly, title: "Yearly", price: "$79.99/yr", badge: "SAVE 33%")
        }
    }

    private func cycleOption(_ cycle: BillingCycle, title: String, price: String, badge: String?) -> some View {
        let selected = billing.billingCycle == cycle
        return Button {
            billing.billingCycle = cycle
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(Typography.font(14, weight: .bold)).foregroundStyle(EColor.onSurface)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(EColor.primary)
                    } else {
                        Circle().stroke(EColor.outlineVariant, lineWidth: 1.5).frame(width: 18, height: 18)
                    }
                }
                Text(price).font(Typography.font(13, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
                if let badge {
                    Text(badge)
                        .font(Typography.font(9, weight: .bold))
                        .foregroundStyle(EColor.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(EColor.secondaryContainer)
                        .clipShape(Capsule())
                } else {
                    // Keeps both cards the same height regardless of
                    // whether their option has a savings badge.
                    Text(" ").font(Typography.font(9, weight: .bold)).opacity(0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? EColor.primary.opacity(0.06) : EColor.surfaceContainerLowest))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? EColor.primary : EColor.outlineVariant, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func upgrade() async {
        isProcessingUpgrade = true
        try? await Task.sleep(nanoseconds: 900_000_000)
        isProcessingUpgrade = false
        withAnimation { billing.isPlus = true }
    }

    // MARK: - Parent Profile (ported from HomeSettingsSheet's parentProfileMenu)

    private var parentProfilePage: some View {
        Form {
            Section {
                parentProfileHero
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            Section("Profile") {
                HStack(spacing: 12) {
                    settingsIconChip("pencil", accent: EColor.primary)
                    Text("Display Name")
                        .font(Typography.font(15, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                    Spacer()
                    TextField("Parent name", text: $parentName)
                        .font(Typography.font(13, weight: .medium))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                }
                .padding(.vertical, 4)

                settingsRow(
                    title: "Email",
                    subtitle: "Not exposed in this prototype",
                    systemImage: "at",
                    value: "Not wired",
                    accent: EColor.primary
                )
            }

            Section("Session") {
                NavigationLink(value: SettingsRoute.signOut) {
                    settingsRow(
                        title: "Sign Out",
                        subtitle: "Remove this parent session from this device",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        accent: EColor.danger,
                        danger: true
                    )
                }
            }

            Section("Danger Zone") {
                Button(role: .destructive) { showDeleteAccountConfirm = true } label: {
                    settingsRow(
                        title: "Delete Account",
                        subtitle: "Permanently delete your account and all family data",
                        systemImage: "trash",
                        accent: EColor.danger,
                        danger: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Parent Profile")
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnTap()
        .alert("Delete your account?", isPresented: $showDeleteAccountConfirm) {
            Button("Delete", role: .destructive) { onSwitchMode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, family data, and every child's profile. This can't be undone.")
        }
    }

    private var parentProfileHero: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Circle().fill(accentColor).frame(width: 88, height: 88)
                    .overlay(Text(initials(from: parentName)).font(Typography.font(28, weight: .heavy)).foregroundStyle(.white))
                    // A thin gold ring on top of the avatar is the same "you can
                    // tell at a glance" signal Opal/similar apps use for a paid
                    // member — nothing extra to read, just present or not.
                    .overlay(
                        Circle()
                            .strokeBorder(
                                billing.isPlus
                                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "FFD972"), Color(hex: "F5A623")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.clear),
                                lineWidth: 3
                            )
                            .padding(-4)
                    )

                VStack(spacing: 8) {
                    Text(parentName)
                        .font(Typography.font(18, weight: .bold))
                        .foregroundStyle(EColor.onSurface)
                    planBadge
                    Text("Email not exposed in this prototype")
                        .font(Typography.font(12, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
            }

            Divider()
                .background(EColor.outlineVariant.opacity(0.7))
                .padding(.top, 14)
                .padding(.bottom, 14)

            accentColorPicker
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(EColor.surfaceContainerLowest))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(EColor.outlineVariant.opacity(0.7), lineWidth: 1))
    }

    // A status pill under the name, the way Opal and similar apps mark a
    // profile as paid/free right on the profile itself rather than only
    // inside a separate billing screen — tapping it (free or Plus) opens
    // the same billing page the root Settings list's "Evlin Plan" row does.
    private var planBadge: some View {
        Button { path.append(SettingsRoute.billing) } label: {
            HStack(spacing: 5) {
                Image(systemName: billing.isPlus ? "crown.fill" : "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(billing.isPlus ? "Evlin Plus" : "Free Plan")
                    .font(Typography.font(12, weight: .bold))
                if !billing.isPlus {
                    Text("· Upgrade")
                        .font(Typography.font(12, weight: .bold))
                        .foregroundStyle(EColor.primary)
                }
            }
            .foregroundStyle(billing.isPlus ? Color(hex: "8A5A00") : EColor.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    billing.isPlus
                        ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "FFEBB0"), Color(hex: "FFD972")], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(EColor.surfaceContainerHigh)
                )
            )
            .overlay(
                Capsule().strokeBorder(billing.isPlus ? Color(hex: "F5A623").opacity(0.5) : EColor.outlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var accentColor: Color { Color(hex: selectedAccentHex) }

    private var accentColorPicker: some View {
        VStack(spacing: 9) {
            Text("Accent Color")
                .font(Typography.font(12, weight: .semibold))
                .foregroundStyle(EColor.outline)
            HStack(spacing: 7) {
                ForEach(SettingsPresentation.accentHexOptions, id: \.self) { hex in
                    Button { selectedAccentHex = hex } label: { accentSwatch(hex) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose accent color \(hex)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func accentSwatch(_ hex: String) -> some View {
        let selected = hex.caseInsensitiveCompare(selectedAccentHex) == .orderedSame
        return ZStack {
            Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(selected ? EColor.onSurface : EColor.outlineVariant, lineWidth: selected ? 2 : 1))
    }

    private func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).compactMap { $0.first }.prefix(2)
        let value = parts.map(String.init).joined().uppercased()
        return value.isEmpty ? "P" : value
    }

    // MARK: - Sign out (ported from HomeSettingsSheet's signOutMenu)

    private var signOutPage: some View {
        Form {
            settingsHeroNote(
                title: "Sign out of this parent phone?",
                message: "Family data stays in the account. This device stops receiving parent notifications until signed in again."
            )

            Section("Confirm") {
                Button(role: .destructive) {
                    path.removeLast(path.count)
                    onSwitchMode()
                } label: {
                    settingsRow(
                        title: "Sign Out",
                        subtitle: "Return this device to onboarding",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        accent: EColor.danger,
                        danger: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Sign Out")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Privacy & Terms (ported from HomeSettingsSheet's privacyTermsMenu)

    private var privacyTermsPage: some View {
        Form {
            Section("Legal") {
                NavigationLink {
                    placeholderPage(title: "Privacy Policy", message: "The in-app privacy policy page is not wired yet.")
                } label: {
                    settingsRow(title: "Privacy Policy", subtitle: "Coming soon", systemImage: "hand.raised", accent: EColor.primary)
                }
                NavigationLink {
                    placeholderPage(title: "Terms of Service", message: "The in-app terms page is not wired yet.")
                } label: {
                    settingsRow(title: "Terms of Service", subtitle: "Coming soon", systemImage: "doc.text", accent: EColor.primary)
                }
            }
        }
        .navigationTitle("Privacy & Terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func placeholderPage(title: String, message: String) -> some View {
        Form {
            settingsHeroNote(title: title, message: message)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Row primitives (ported 1:1 from HomeSettingsSheet's row builders)

    private enum SettingsPillTone {
        case success, neutral, warning
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        systemImage: String,
        value: String? = nil,
        pill: String? = nil,
        pillTone: SettingsPillTone = .neutral,
        accent: Color = EColor.primary,
        danger: Bool = false,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            settingsIconChip(systemImage, accent: accent, disabled: disabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.font(15, weight: .semibold))
                    .foregroundStyle(disabled ? EColor.outline : (danger ? EColor.danger : EColor.onSurface))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.font(12, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            if let value, !value.isEmpty {
                Text(value)
                    .font(Typography.font(13, weight: .medium))
                    .foregroundStyle(disabled ? EColor.outline : EColor.onSurfaceVariant)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            if let pill, !pill.isEmpty {
                settingsPill(pill, tone: pillTone)
            }
        }
        .padding(.vertical, 4)
        .opacity(disabled ? 0.72 : 1)
    }

    private func settingsIconChip(_ systemImage: String, accent: Color, disabled: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(disabled ? EColor.outline : accent)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(disabled ? EColor.surfaceContainerHigh : accent.opacity(0.12)))
    }

    private func settingsPill(_ text: String, tone: SettingsPillTone) -> some View {
        let colors = pillColors(tone)
        return Text(text)
            .font(Typography.font(12, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(colors.background))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func pillColors(_ tone: SettingsPillTone) -> (foreground: Color, background: Color) {
        switch tone {
        case .success: return (EColor.secondary, EColor.secondaryContainer.opacity(0.65))
        case .warning: return (EColor.primary, EColor.tertiaryContainer.opacity(0.65))
        case .neutral: return (EColor.outline, EColor.surfaceContainerHigh)
        }
    }

    private func settingsProfileCard(title: String, subtitle: String, initials: String, accent: Color = EColor.primary) -> some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(Typography.font(16, weight: .bold))
                .foregroundStyle(EColor.onPrimary)
                .frame(width: 46, height: 46)
                .background(Circle().fill(accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.font(16, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text(subtitle).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant).lineLimit(2)
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 6)
    }

    private func settingsHeroNote(title: String, message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text(message).font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
            }
            .padding(.vertical, 4)
        }
    }
}

enum SettingsPresentation {
    static let accentHexOptions = [
        "#24324A", "#2E7D32", "#7C6FF7", "#EF6C00", "#0F766E", "#BE185D", "#2563EB", "#6B7280",
    ]
}

// MARK: - Add Child (mocked pairing — any 6-digit code "pairs" after a short
// delay, same convention as OnboardingV2ParentSteps' ParentPairScanStep,
// whose faux-QR/camera-preview and code-field components this reuses so the
// two pairing screens in the app look and behave the same way).

// Edit an existing child's name, age, and picture — Add Child (below) only
// ever creates a new profile, there was previously no way to fix a typo'd
// name or set a photo after the fact.
private struct EditChildProfileSheet: View {
    @ObservedObject var child: Child
    var onSave: (_ name: String, _ age: Int, _ avatar: UIImage?) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var age: Int
    @State private var avatar: UIImage?

    init(child: Child, onSave: @escaping (_ name: String, _ age: Int, _ avatar: UIImage?) -> Void, onCancel: @escaping () -> Void) {
        self.child = child
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: child.name)
        _age = State(initialValue: child.age)
        _avatar = State(initialValue: child.avatar)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        // Same picker onboarding uses for the parent/child
                        // avatar step, so picking a photo here looks and
                        // behaves identically to picking one there.
                        OnboardingV2PhotoAvatarPicker(name: name, pickedImage: $avatar, size: 84)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section("Name") {
                    TextField("Child's name", text: $name)
                        .font(Typography.font(15, weight: .regular))
                }
                Section("Age") {
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                        .font(Typography.font(15, weight: .regular))
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name.trimmingCharacters(in: .whitespaces), age, avatar) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct SettingsAddChildSheet: View {
    var onAdd: (String, Int) -> Void
    var onCancel: () -> Void

    private enum Step { case scan, name }
    @State private var step: Step = .scan
    @State private var code = ""
    @State private var busy = false
    @State private var name = ""
    @State private var age = 8
    // A real, decodable QR now (not OnboardingV2FauxQR's decorative noise)
    // — same encode(code:) payload ChildShowCodeStep writes on the kid
    // side, so this actually round-trips through a real QR scanner if
    // someone points one at it, standing in for the child device's own
    // generated code in this single-device prototype.
    @State private var demoChildCode = String(format: "%06d", Int.random(in: 0...999999))

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scan: scanStep
                case .name: nameStep
                }
            }
            .navigationTitle("Add Child")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
            .dismissKeyboardOnTap()
        }
    }

    private var scanStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Pair Your Child's Device")
                    .font(Typography.font(20, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                Text("Scan the QR code shown on the child's app, or enter the 6-digit code manually below.")
                    .font(Typography.font(13, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 24)

            ZStack {
                OnboardingV2QRImage(string: OnboardingV2PairPayload.encode(code: demoChildCode), side: 168)
                OnboardingV2ScanLine(size: 200)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .padding(18)
            }
            .frame(width: 240, height: 240)
            .background(Color(hex: "1B1F24"))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .bottom) {
                Text("Camera preview (demo)")
                    .font(Typography.font(11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 10)
            }

            OnboardingV2CodeField(code: $code)
                .onChange(of: code) { _, newValue in
                    // Rewriting a TextField's own bound text synchronously
                    // from inside its own onChange, while the keyboard's
                    // input session for that keystroke is still live, is a
                    // known crash trigger (RTIInputSystemClient /
                    // NSTaggedPointerString on-device). Defer the rewrite
                    // to the next run loop tick so that transaction
                    // finishes first.
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue {
                        DispatchQueue.main.async { code = digits }
                    }
                    if digits.count == 6 && !busy { pair() }
                }
                .padding(.horizontal, 24)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Pairing…").font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EColor.surface)
    }

    private func pair() {
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            busy = false
            withAnimation(.easeOut(duration: 0.2)) { step = .name }
        }
    }

    private var nameStep: some View {
        Form {
            Section {
                Text("Device paired. What's your child's name?")
                    .font(Typography.font(12, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
            }
            Section {
                TextField("Child's name", text: $name).font(Typography.font(15, weight: .regular))
                Stepper("Age: \(age)", value: $age, in: 1...18).font(Typography.font(15, weight: .regular))
            }
            Section {
                Button {
                    onAdd(name.trimmingCharacters(in: .whitespaces), age)
                } label: {
                    Text("Add Child")
                        .font(Typography.font(15, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
