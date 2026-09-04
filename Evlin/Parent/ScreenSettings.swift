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
    case notifications
    case coParents
    case privacyTerms
    case childrenDevices
    case billing
}

struct ScreenSettings: View {
    var onSwitchMode: () -> Void
    @State private var path = NavigationPath()
    @State private var openChildId: String?

    // Root notification toggle — mirrors the source's `notifyPushEnabled`.
    @State private var pushOn = true
    // Detail-page alert types — source's per-type @AppStorage toggles.
    @State private var notifyKidRequests = true
    @State private var notifyReflectionCompletions = true
    @State private var notifyKidNudges = true
    @State private var notifyWeeklySummary = false

    // Parent profile — source's parentName/selectedParentAccentHex.
    @State private var parentName = "Alex Carter"
    @State private var selectedAccentHex = SettingsPresentation.accentHexOptions[0]

    // Co-parents — source's familyStore.parents.filter { !is_owner }.
    @State private var coParents: [String] = []
    @State private var showInviteCoParent = false
    @State private var inviteCode = "482913"

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
            Form {
                settingsRootContent
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .parentProfile: parentProfilePage
                case .signOut: signOutPage
                case .notifications: notificationsPage
                case .coParents: coParentsPage
                case .privacyTerms: privacyTermsPage
                case .childrenDevices: childrenDevicesPage
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
        .sheet(isPresented: $showInviteCoParent) {
            SettingsInviteCoParentSheet(code: inviteCode) { showInviteCoParent = false }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Root (ported from HomeSettingsSheet's settingsRootContent)

    @ViewBuilder
    private var settingsRootContent: some View {
        Section {
            NavigationLink(value: SettingsRoute.parentProfile) {
                settingsProfileCard(
                    title: parentName,
                    subtitle: "Parent account · My Family",
                    initials: initials(from: parentName)
                )
            }
        }

        // Not duplicated at root any more — the "Plan" row inside Parent
        // Profile (account management, not a pitch) is the one place for
        // it now, so a parent isn't looking at two entry points into the
        // same billingPage.
        Section("Share") {
            ShareLink(item: "I've been using Evlin to manage screen time for my kids — thought you might like it too.") {
                settingsRow(
                    title: "Share Evlin",
                    subtitle: "Invite another parent to try it",
                    systemImage: "square.and.arrow.up",
                    accent: EColor.primary
                )
            }
        }

        Section("Family") {
            NavigationLink(value: SettingsRoute.childrenDevices) {
                settingsRow(
                    title: "Children & Devices",
                    subtitle: childrenDevicesSummary,
                    systemImage: "person",
                    value: "\(FamilyStore.children.count) \(FamilyStore.children.count == 1 ? "child" : "children")",
                    accent: EColor.primary
                )
            }

            NavigationLink(value: SettingsRoute.coParents) {
                settingsRow(
                    title: "Co-parents",
                    subtitle: coParentSubtitle,
                    systemImage: "person.2",
                    value: coParentValue,
                    accent: EColor.secondary
                )
            }

            Button {
                showAddChild = true
            } label: {
                settingsRow(
                    title: "Add Child",
                    subtitle: "Scan the new child's first device",
                    systemImage: "plus",
                    accent: EColor.primary
                )
            }
        }

        Section("Notifications") {
            settingsNavigableToggleRow(
                title: "Push Notifications",
                subtitle: notificationRootSubtitle,
                systemImage: "bell",
                isOn: $pushOn,
                accent: EColor.secondary,
                navigate: { path.append(SettingsRoute.notifications) }
            )
        }

        Section("About") {
            settingsRow(
                title: "Replay the tours",
                subtitle: "Re-run each tab's quick intro",
                systemImage: "sparkles",
                accent: EColor.primary
            )

            settingsRow(
                title: "Version",
                subtitle: "",
                systemImage: "info.circle",
                value: "1.0 (100)",
                accent: EColor.primary
            )

            NavigationLink(value: SettingsRoute.privacyTerms) {
                settingsRow(
                    title: "Privacy & Terms",
                    subtitle: "Policies and service terms",
                    systemImage: "shield",
                    accent: EColor.primary
                )
            }
        }
    }

    private var childrenDevicesSummary: String {
        let ages = FamilyStore.children.map(\.age)
        return "Age range \(ages.min() ?? 0)–\(ages.max() ?? 0) · \(FamilyStore.children.count) child devices"
    }

    private var coParentSubtitle: String { coParents.isEmpty ? "Invite another parent or caregiver" : "Manage family-level access" }
    private var coParentValue: String { coParents.isEmpty ? "None" : "\(coParents.count) adults" }

    private var notificationRootSubtitle: String {
        "\(pushOn ? "Allowed" : "Off") · kid requests, completions, alerts"
    }

    // MARK: - Children & Devices (ported from HomeSettingsSheet's childrenDevicesMenu)

    private var childrenDevicesPage: some View {
        Form {
            settingsHeroNote(
                title: "Family devices are scoped by child.",
                message: "Choose which kid/device you are managing. App lists and controls live under the child device, not on the parent phone."
            )

            Section("Children") {
                ForEach(FamilyStore.children) { child in
                    Button { openChildId = child.id } label: {
                        settingsChildRow(child)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            childPendingRemoval = child
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }

            Section("Setup") {
                Button {
                    showAddChild = true
                } label: {
                    settingsRow(
                        title: "Add Child",
                        subtitle: "Scan the new child's first device",
                        systemImage: "qrcode.viewfinder",
                        accent: EColor.primary
                    )
                }
            }

            // Moved here from each kid's own profile screen (ScreenProfile)
            // — device management reads as a settings-level concern, same
            // as the child list right above it, not something that belongs
            // mixed into a kid's day-to-day task/rules dashboard.
            Section("Registered Devices") {
                ForEach(FamilyStore.children) { child in
                    ForEach(child.devices) { device in
                        deviceRow(device)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    FamilyStore.removeDevice(device.id, from: child.id)
                                    familyRefreshTick += 1
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Children & Devices")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private func deviceRow(_ device: RegisteredDevice) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(EColor.primaryContainer)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "iphone").font(.system(size: 19, weight: .semibold)).foregroundStyle(EColor.primary))
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(Typography.font(14.5, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text("\(device.model) · \(device.osVersion)").font(Typography.font(12, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                Text("Paired \(device.pairedOn)").font(Typography.font(11, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            Text(device.lastActive)
                .font(Typography.font(11, weight: .bold))
                .foregroundStyle(device.lastActive == "Active now" ? Color(hex: "25924A") : EColor.onSurfaceVariant)
        }
        .padding(.vertical, 4)
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

    // MARK: - Notifications detail (ported from HomeSettingsSheet's notificationsMenu)

    private var notificationsPage: some View {
        Form {
            settingsHeroNote(
                title: "Parent-side permission.",
                message: "This replaces Screen Time on the parent phone. The parent mainly needs alerts for kid requests, completions, and nudges."
            )

            Section("Permission") {
                settingsToggleRow(
                    title: "Push Notifications",
                    subtitle: "System permission for parent alerts",
                    systemImage: "bell",
                    isOn: $pushOn,
                    accent: EColor.secondary
                )
            }

            Section {
                Toggle(isOn: $notifyKidRequests) {
                    settingsRow(title: "Kid requests", subtitle: "Bypass requests, help requests", systemImage: "bell", accent: EColor.secondary)
                }
                Toggle(isOn: $notifyReflectionCompletions) {
                    settingsRow(title: "Reflection completions", subtitle: "Notify when a kid finishes", systemImage: "checkmark.circle", accent: EColor.secondary)
                }
                Toggle(isOn: $notifyKidNudges) {
                    settingsRow(title: "Nudges from kid device", subtitle: "Kid asks parent to review", systemImage: "hand.raised", accent: EColor.secondary)
                }
                Toggle(isOn: $notifyWeeklySummary) {
                    settingsRow(title: "Weekly summary", subtitle: "Optional progress digest", systemImage: "calendar", accent: EColor.primary)
                }
            } header: {
                Text("Alert Types")
            } footer: {
                Text("These switches are local presentation settings — there's no backend routing in this prototype.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Co-parents (ported from HomeSettingsSheet's coParentsMenu)

    private var coParentsPage: some View {
        Form {
            settingsHeroNote(
                title: "Family-level access belongs here.",
                message: "Co-parents are not connected to app controls. They manage people, alerts, approvals, and family visibility."
            )

            Section("Parents") {
                if coParents.isEmpty {
                    settingsRow(
                        title: "No co-parents yet",
                        subtitle: "Invite another parent or caregiver when needed",
                        systemImage: "person.2",
                        value: "None",
                        accent: EColor.secondary
                    )
                }

                ForEach(coParents, id: \.self) { name in
                    settingsRow(title: name, subtitle: "Co-parent", systemImage: "person.2", accent: EColor.secondary)
                }

                Button {
                    showInviteCoParent = true
                } label: {
                    settingsRow(title: "Invite Co-parent", subtitle: "Create and share an invite code", systemImage: "plus", accent: EColor.primary)
                }
            }

            Section {
                settingsRow(title: "Can receive kid requests", subtitle: "Family notification access", systemImage: "checkmark.circle", value: "On", accent: EColor.secondary)
                settingsRow(title: "Can approve tasks", subtitle: "Approval permissions", systemImage: "checkmark.circle", value: "On", accent: EColor.secondary)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Permission editing is not wired yet; current rows describe the intended family-level model.")
            }
        }
        .navigationTitle("Co-parents")
        .navigationBarTitleDisplayMode(.inline)
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

            // Its own section (not folded into "Profile") so it reads as
            // account-level, same as Session below — and its own row here
            // is a clear a link into the same billing page as the root
            // list's "Evlin Plan" row, not a second copy of that screen.
            Section("Plan") {
                NavigationLink(value: SettingsRoute.billing) {
                    settingsRow(
                        title: "Evlin Plan",
                        subtitle: billing.isPlus ? "Evlin Plus · \(billing.billingCycle == .yearly ? "Yearly" : "Monthly")" : "Upgrade for unlimited rules & AI insights",
                        systemImage: "sparkles",
                        pill: billing.isPlus ? "PLUS" : "FREE",
                        pillTone: billing.isPlus ? .success : .neutral,
                        accent: EColor.primary
                    )
                }
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

                VStack(spacing: 3) {
                    Text(parentName)
                        .font(Typography.font(18, weight: .bold))
                        .foregroundStyle(EColor.onSurface)
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

    private func settingsToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        accent: Color = EColor.primary
    ) -> some View {
        HStack(spacing: 12) {
            settingsIconChip(systemImage, accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurface)
                Text(subtitle).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant).lineLimit(2)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: isOn).labelsHidden().tint(EColor.secondary)
        }
        .padding(.vertical, 4)
    }

    private func settingsNavigableToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        accent: Color = EColor.primary,
        navigate: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: navigate) {
                HStack(spacing: 12) {
                    settingsIconChip(systemImage, accent: accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurface)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: isOn).labelsHidden().tint(EColor.secondary).fixedSize()

            Button(action: navigate) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EColor.outline)
                    .frame(width: 18, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func settingsIconChip(_ systemImage: String, accent: Color, disabled: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(disabled ? EColor.outline : accent)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(disabled ? EColor.surfaceContainerHigh : accent.opacity(0.12)))
    }

    private func settingsChildRow(_ child: Child) -> some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: child.name, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(child.name).font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurface)
                Text("Age \(child.age) · 1 device").font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant).lineLimit(2)
            }
            Spacer(minLength: 10)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(EColor.outline)
        }
        .padding(.vertical, 4)
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
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { code = digits }
                    if digits.count > 6 { code = String(digits.prefix(6)) }
                    if code.count == 6 && !busy { pair() }
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

private struct SettingsInviteCoParentSheet: View {
    var code: String
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.badge.plus").font(.system(size: 48, weight: .semibold)).foregroundStyle(EColor.secondary)
                Text("Invite code").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text(code)
                    .font(Typography.font(32, weight: .heavy))
                    .tracking(4)
                    .foregroundStyle(EColor.primary)
                Text("Share this code with a co-parent. It's a demo value — this prototype has no real invite backend.")
                    .font(Typography.font(12, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EColor.surface)
            .navigationTitle("Invite Co-parent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}
