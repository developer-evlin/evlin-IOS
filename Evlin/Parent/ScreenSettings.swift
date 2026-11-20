import SwiftUI

// Structured to the "Settings — build spec" doc: account header (no card,
// opens a sheet) → Plan (removed entirely on Pro) → Family (capped list,
// each row opening the Child sheet) → Alerts → Support → a muted text
// footer. Every row is exactly one of chevron/toggle/read-only-value —
// never mixed. The account name is edited as a draft and saved explicitly;
// other edits happen live inside the sheet a row opens. Destructive actions
// never use an inline alert; they open DestructiveConfirmSheet instead.
struct ScreenSettings: View {
    var onSwitchMode: () -> Void
    var onSignOut: (() -> Void)? = nil

    // Root notification toggle — the only notification setting there is.
    @State private var pushOn = true
    @AppStorage(Appearance.key) private var appearance: Appearance = .cream

    // Parent identity — shown in the account header and edited in the
    // account sheet (parentProfilePage).
    private var profile: ParentProfile { ParentProfile.shared }
    private var parentName: String { profile.displayName }

    // The child whose profile (ChildSettingsSheet) is open.
    @State private var settingsChild: Child?
    // "Add a child" creates a placeholder profile immediately and goes
    // straight to the QR pairing screen — no name/colour form first, and
    // no follow-up sheet once pairing closes either. The parent renames/
    // recolours/re-times the child later the same way as any other row:
    // tapping it opens settingsChild (ChildSettingsSheet) directly.
    @State private var newlyAddedChild: Child?
    // FamilyStore isn't itself observable — bumping this after a mutation
    // (add/remove a child) is what makes SwiftUI re-evaluate body and pick
    // up the change. Not needed for in-place edits inside the Child sheet
    // (name/colour/limit/device) since those mutate an @Published property
    // on the same Child instance the sheet already observes, and dismissing
    // that sheet re-renders this screen's body anyway.
    @State private var familyRefreshTick = 0
    // With more than one child, Children opens a list of profiles first
    // (a pushed page); with one child it opens the profile directly.
    @State private var showChildrenList = false

    // Account/plan/legal sheets — chevron rows on the root list, each
    // opening a sheet rather than pushing.
    @State private var showParentProfile = false
    @State private var parentNameDraft = ""
    @State private var savedParentName = ""
    @State private var showBilling = false
    /// Settings' Screen time access code row, tapped (`AccessCodeOpener`).
    @State private var askAccessCode = false
    /// The plan page, opened by Add a child on the free plan's one child.
    @State private var showChildPaywall = DemoMode.parentOpen == "childpaywall"
    // Pages inside the Account sheet.
    @State private var showEditAccount = false
    @State private var showLegal = false

    // Destructive confirmations — always a sheet, never an inline alert.
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccountConfirm = false

    // Shared (BillingState.shared, not local @State) so the account card's
    // plan badge follows the plan page. Upgrade offers show only while
    // EvlinPlan.offered (no StoreKit yet).
    @ObservedObject private var billing = BillingState.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                settingsRootContent
            }
            // Home's page colour, so the tabs read as one app.
            .background(EColor.surface)
            // Custom header (SettingsProfileHead) replaces the system nav
            // bar on this root screen — every destination below now opens
            // as its own sheet instead of pushing, so this stack never
            // actually navigates anywhere itself.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChildrenList) {
                childListPage(title: "Children") { settingsChild = $0 }
            }
        }
        .sheet(item: $settingsChild) { child in
            Group {
            ChildSettingsSheet(child: child, onRemoved: { familyRefreshTick += 1 })
        }
            .presentationDragIndicator(.visible)
        }
        // Straight into pairing the moment "Add a child" is tapped — see
        // the Add a child row's action. The child this holds is only ever in
        // memory, not FamilyStore, until pairing actually succeeds (see
        // onPaired below) — so a child that's never paired never shows up
        // in the Family list or on Home. Closing this is the end of the
        // flow either way; naming/colouring happens later from the child's
        // own row, whenever the parent gets to it.
        .sheet(item: $newlyAddedChild) { child in
            Group {
            PairingSheet(child: child, isNewChild: true, onPaired: {
                // The backend created the real child when it issued the
                // code; the sync inside PairingSheet has already loaded it.
                familyRefreshTick += 1
            })
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showParentProfile) {
            Group {
            parentProfilePage
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBilling) {
            EvlinPlanSheet()
                .presentationDragIndicator(.visible)   // nothing to lose here: swipes away
        }
        .sheet(isPresented: $showChildPaywall) {
            // Bought, it closes and goes straight on to adding the child.
            EvlinPlanSheet(reason: .anotherChild) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startAddingChild() }
            }
            .presentationDragIndicator(.visible)
        }
        .onAppear { if DemoMode.parentOpen == "child", settingsChild == nil { settingsChild = FamilyStore.children.first } }
        // Demo: `account` / `edit` open the Account page once Settings is up.
        .task {
            guard ["account", "edit"].contains(DemoMode.parentOpen ?? "") else { return }
            try? await Task.sleep(for: .seconds(0.8))
            showParentProfile = true
            guard DemoMode.parentOpen == "edit" else { return }
            try? await Task.sleep(for: .seconds(0.8))
            parentNameDraft = profile.name
            savedParentName = profile.name
            showEditAccount = true
        }
    }

    /// A new child, held in memory only until pairing succeeds (the
    /// newlyAddedChild sheet's onPaired), so a child that's never paired
    /// never appears anywhere.
    private func startAddingChild() {
        newlyAddedChild = Child(
            id: UUID().uuidString, name: "New Child", age: 8, dailyLimitMin: 60,
            color: FamilyStore.nextChildColor(), manualLock: false, taskGateOverride: false, timeLeft: formatMinutes(60), timePct: 100,
            usageTodayMin: 0, subtitle: "No tasks yet"
        )
    }

    // MARK: - Root
    //
    // Hand-built instead of Form/Section: single-line rows by default (no
    // subtitle unless the row would otherwise be ambiguous — none here
    // are), small uppercase labels sitting tight against the group they
    // name, rows on a plain white page separated by hairline dividers —
    // Instagram-style, not Form's own insetGrouped card styling.

    // Four rules govern everything below:
    // 1. Cards separate by cardinality, not topic — a list of entities
    //    (Family) gets one card per entity; a set of facets about one
    //    subject (Account+Plan, Alerts, Support) gets one card with
    //    hairlines inside.
    // 2. A card is a tap target or a container, never both — an
    //    entity card (a child, "Add a child") is entirely tappable;
    //    a facet card's rows are tappable, the card itself does nothing.
    // 3. Gap size encodes relationship — 8pt between cards in a group,
    //    24pt between groups, so the grouping is visible from spacing
    //    alone.
    // 4. Section headings (SectionHead — 20pt heavy black, same weight
    //    as Home's "Current Tasks") sit outside the cards. Small grey
    //    uppercase is reserved for form-field labels inside sheets.
    // One quiet list, the way modern apps lay out Settings: a line icon and a
    // title per row, a grey value or a switch where there's one, hairlines
    // between groups, no section headings and no cards.
    @ViewBuilder
    private var settingsRootContent: some View {
        let children = FamilyStore.children
        VStack(alignment: .leading, spacing: 0) {
            // A sheet now, not a tab: the same room under the grab line
            // whatever the number of children, so the title never jams
            // against the top (it did with one child).
            // The parent's own head in place of the "Settings" title
            // (2026-11-17, the user's call): name, plan and Upgrade.
            SettingsProfileHead(onAccount: {
                parentNameDraft = profile.name
                savedParentName = profile.name
                showParentProfile = true
            }, onUpgrade: { showBilling = true })
                .padding(.top, 22)
                .padding(.bottom, 20)


            // Related rows together, one line between groups.
            SettingsCard {
                // The account is the head over this, one row with a › (the
                // way to Sign out and Delete account), and the free plan's
                // Upgrade under it (2026-11-17, the user's call: the head and
                // a separate Account row showed the name twice). On Pro, the
                // plan to manage.
                if billing.isPlus || !EvlinPlan.offered {
                    ManageRow(icon: "leaf.fill", title: "Manage subscription",
                              value: billing.isPlus ? "Pro" : "Free plan", tile: SettingsTile.plan,
                              showChevron: billing.isPlus) {
                        if billing.isPlus { showBilling = true }
                    }
                    SettingsGroupGap()
                }
                // One child: straight to their profile. More: their profiles first.
                if !children.isEmpty {
                    ManageRow(icon: "figure.2.and.child.holdinghands",
                              title: children.count == 1 ? children[0].name : "Children",
                              value: children.count == 1 ? nil : "\(children.count)", tile: SettingsTile.children) {
                        if children.count == 1 { settingsChild = children[0] } else { showChildrenList = true }
                    }
                }
                ManageRow(icon: "person.badge.plus", title: "Add a child", tile: SettingsTile.addChild, showChevron: false) {
                    // The free plan covers one child: a second opens the
                    // plan page first, saying why (EvlinPlan.needsPro).
                    if EvlinPlan.needsPro(toAddTo: children.count) {
                        showChildPaywall = true
                    } else {
                        startAddingChild()
                    }
                }
                HStack(spacing: 16) {
                    SettingsTileIcon(icon: "bell.badge.fill", color: SettingsTile.notifications)
                    Text("Notifications")
                        .font(SettingsType.title)
                        .foregroundStyle(EColor.onSurface)
                    Spacer(minLength: 10)
                    EToggle(on: $pushOn, color: StatusCardStyle.green)
                        .accessibilityLabel("Notifications")
                }
                .frame(minHeight: SettingsType.rowHeight)
                // No "Task template library" switch: New task always has its
                // Library (2026-11-19, the user's call).
                // Cream or Dark.
                HStack(spacing: 16) {
                    SettingsTileIcon(icon: "circle.lefthalf.filled", color: SettingsTile.appearance)
                    Text("Appearance")
                        .font(SettingsType.title)
                        .foregroundStyle(EColor.onSurface)
                    Spacer(minLength: 10)
                    AppearanceSwitch(appearance: $appearance)
                }
                .frame(minHeight: SettingsType.rowHeight)
                // What a parent types on any of their children's devices to
                // get into its settings (2026-11-19, the user's call: here,
                // not on Profile, as parents won't use it much). Face ID first.
                ManageRow(icon: "key.fill", title: "Screen time access code", tile: SettingsTile.accessCode) {
                    askAccessCode = true
                }

                SettingsGroupGap()
                // A mailbox, not a help centre; the prefilled details make "it's
                // not working" traceable.
                ManageRow(icon: "exclamationmark.bubble.fill", title: "Report a problem", tile: SettingsTile.report) {
                    if let url = reportProblemURL { UIApplication.shared.open(url) }
                }
                ShareLink(item: "I've been using Evlin to manage screen time for my kids — thought you might like it too.") {
                    ManageRowLabel(icon: "square.and.arrow.up", title: "Invite a friend", tile: SettingsTile.invite)
                }
                .buttonStyle(SettingsTapStyle())
            }
        }
        // Keyed on the tick so adding or removing a child redraws the rows
        // that depend on how many children there are.
        .id(familyRefreshTick)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 120)
        .modifier(AccessCodeOpener(asked: $askAccessCode))
        // Demo: `-EvlinParentTab 3 -EvlinParentOpen accesscode` opens it.
        .task {
            guard DemoMode.parentOpen == "accesscode" else { return }
            try? await Task.sleep(for: .seconds(0.9))
            askAccessCode = true
        }
    }

    /// The family's profiles, for Children when there's more than one
    /// child. Tapping one opens it.
    private func childListPage(title: String, open: @escaping (Child) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(FamilyStore.children) { child in
                    Button { open(child) } label: {
                        HStack(spacing: 16) {
                            Circle().fill(child.color).frame(width: 36, height: 36)
                                .overlay(Text(String(child.name.prefix(1))).font(Typography.font(15, weight: .bold)).foregroundStyle(.white))
                            Text(child.name)
                                .font(Typography.font(16.5, weight: .medium))
                                .foregroundStyle(EColor.onSurface)
                            Spacer(minLength: 10)
                            Text(child.devices.isEmpty ? "Not paired" : "\(child.devices.count) \(child.devices.count == 1 ? "device" : "devices")")
                                .font(Typography.font(15, weight: .regular))
                                .foregroundStyle(Color(.secondaryLabel))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsTapStyle())
                }
            }
            .id(familyRefreshTick)
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
        .background(EColor.surface)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Account: your name, sign-in email, and at the very end Delete
    // account (Apple requires it to be reachable in the app, not on show).
    // Opened by the Account row on the Settings list.
    private var parentProfilePage: some View {
        NavigationStack {
            accountHome
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showEditAccount) { editAccountPage }
                .navigationDestination(isPresented: $showLegal) { privacyTermsPage }
        }
        .background(EColor.surface)
        .onAppear {
            if parentNameDraft.isEmpty && savedParentName.isEmpty {
                parentNameDraft = profile.name
                savedParentName = profile.name
            }
        }
        .sheet(isPresented: $showSignOutConfirm) {
            Group {
            DestructiveConfirmSheet(
                title: "Sign out of this parent phone?",
                consequences: [
                    "Family data stays in the account.",
                    "This device stops receiving parent notifications until signed in again.",
                ],
                destructiveLabel: "Sign Out",
                onConfirm: {
                    showSignOutConfirm = false
                    showParentProfile = false
                    SessionManager.shared.clear()
                    FamilyStore.clear()
                    onSignOut?() ?? onSwitchMode()
                },
                onCancel: { showSignOutConfirm = false }
            )
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDeleteAccountConfirm) {
            Group {
            DestructiveConfirmSheet(
                title: "Delete your account?",
                consequences: [
                    "Every child is signed out of their device immediately.",
                    "All screen time locks and rules stop being enforced.",
                    "Every child's profile, tasks, and history are permanently deleted.",
                    "This can't be undone.",
                ],
                destructiveLabel: "Delete Account",
                onConfirm: {
                    Task {
                        // Only sign out once the server has actually deleted the
                        // account; otherwise the account would still exist.
                        do {
                            try await APIClient.shared.deleteAccount()
                            showDeleteAccountConfirm = false
                            showParentProfile = false
                            SessionManager.shared.clear()
                            FamilyStore.clear()
                            onSignOut?() ?? onSwitchMode()
                        } catch {
                            showDeleteAccountConfirm = false
                            SyncState.shared.writeError = "Your account wasn't deleted. \(error.apiUserMessage)"
                        }
                    }
                },
                onCancel: { showDeleteAccountConfirm = false }
            )
        }
            .presentationDragIndicator(.visible)
        }
    }

    /// The Account sheet: who's signed in, then Edit account, Privacy and
    /// terms, the version, and Sign out, as rows like the Settings list.
    private var accountHome: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showParentProfile = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsTapStyle())
                .accessibilityLabel("Close")
            }
            .overlay {
                Text("Account")
                    .font(Typography.font(17, weight: .bold))
                    .foregroundStyle(EColor.onSurface)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Text(String(parentName.prefix(1)).uppercased())
                            .font(Typography.font(22, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(SettingsTile.account))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(parentName)
                                .font(Typography.font(20, weight: .heavy))
                                .foregroundStyle(EColor.onSurface)
                            if !profile.email.isEmpty {
                                Text(profile.email)
                                    .font(SettingsType.value)
                                    .foregroundStyle(SettingsType.valueColor)
                            }
                        }
                    }
                    .padding(.vertical, 18)

                    ManageRow(icon: "pencil", title: "Edit account", tile: SettingsTile.account) {
                        parentNameDraft = profile.name
                        savedParentName = profile.name
                        showEditAccount = true
                    }
                    ManageRow(icon: "hand.raised.fill", title: "Privacy and terms", tile: SettingsTile.privacy) {
                        showLegal = true
                    }
                    ManageRowLabel(icon: "info", title: "Version", value: appVersionString,
                                   tile: SettingsTile.report, showChevron: false)
                    // On its own, apart from the rest, as Apple sets off a
                    // destructive action.
                    SettingsGroupGap()
                    ManageRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", tint: EColor.danger,
                              tile: SettingsTile.notifications, showChevron: false) {
                        showSignOutConfirm = true
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(EColor.surface)
    }

    /// Edit account: the name (saved with Save), and at the very end,
    /// deleting the account.
    private var editAccountPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FormField(label: "Your name") {
                    FormTextField(placeholder: "Your name", text: $parentNameDraft)
                }

                // No email here (2026-11-17, the user's call): it can't be
                // changed in the app; the Account page shows it under the name.

                VStack(alignment: .leading, spacing: 0) {
                    ManageDivider()
                    ManageRow(icon: "trash", title: "Delete account", tint: EColor.danger, showChevron: false) {
                        showDeleteAccountConfirm = true
                    }
                    Text("Removes every child's profile, tasks and history for good, and signs their devices out.")
                        .font(Typography.font(12, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .dismissKeyboardOnTap()
        .scrollDismissesKeyboard(.interactively)
        .background(EColor.surface)
        .navigationTitle("Edit account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if parentNameHasChanges {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        TapHaptic.play()
                        let name = parentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        profile.name = name
                        profile.saveIfChanged()
                        parentNameDraft = name
                        savedParentName = name
                    }
                    .font(Typography.font(16, weight: .bold))
                    .foregroundStyle(EvlinPlan.accent)
                    .disabled(parentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var parentNameHasChanges: Bool {
        parentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != savedParentName
    }

    // MARK: - Privacy & Terms

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
        .navigationTitle("Privacy and terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func placeholderPage(title: String, message: String) -> some View {
        Form {
            settingsHeroNote(title: title, message: message)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Row primitives

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

// MARK: - Destructive confirmation (the "second sheet" every destructive
// action in this file opens instead of an inline alert — states exactly
// what happens, destructive button on top, safe escape below it).

private struct DestructiveConfirmSheet: View {
    var title: String
    var consequences: [String]
    var destructiveLabel: String
    var cancelLabel: String = "Cancel"
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(Typography.font(20, weight: .bold))
                .foregroundStyle(EColor.onSurface)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(consequences, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(EColor.onSurfaceVariant).frame(width: 4, height: 4).padding(.top, 7)
                        Text(line).font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button { onConfirm() } label: {
                    Text(destructiveLabel)
                        .font(Typography.font(16, weight: .bold))
                        .foregroundStyle(EColor.onDangerFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(EColor.dangerFill)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(SettingsTapStyle())

                Button { onCancel() } label: {
                    Text(cancelLabel)
                        .font(Typography.font(16, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(EColor.surfaceContainerHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(SettingsTapStyle())
            }
        }
        .padding(24)
        .presentationBackground(EColor.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Child sheet — everything that belongs to a child's own identity
// and device: picture, name, and the device row. Colour and daily screen
// time aren't parent-editable here any more — a sensible default is set
// silently at creation. Nothing here is an enforcement rule (downtime/
// bedtime/app picker live on that child's own screen elsewhere) — this is
// account settings for one child. Edits apply immediately; dismissing is
// "Done," never
// "Cancel," because nothing is ever pending. Same chrome/palette as
// FormShell (green "Done" link, big bold title, mint fields) so this reads
// as the same family of sheet as Add a Child/Add Task, just without a
// bottom Save pill — there's nothing queued up to save.
/// A row on an account or device page, the way modern apps lay them out: a
/// line icon, the title, an optional grey value, a chevron when it opens a
/// page. The whole row is the button.
private struct ManageRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var tint: Color = EColor.onSurface
    /// A coloured tile behind a white icon (the Settings list), or none for
    /// a plain line icon (rows inside a sheet).
    var tile: Color? = nil
    var showChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ManageRowLabel(icon: icon, title: title, value: value, tint: tint, tile: tile, showChevron: showChevron)
        }
        .buttonStyle(SettingsTapStyle())
    }
}

/// What a ManageRow shows, for rows that aren't plain buttons (a ShareLink).
private struct ManageRowLabel: View {
    let icon: String
    let title: String
    var value: String? = nil
    var tint: Color = EColor.onSurface
    var tile: Color? = nil
    var showChevron = true

    var body: some View {
        HStack(spacing: 16) {
            if let tile {
                SettingsTileIcon(icon: icon, color: tile)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 28)
            }
            Text(title)
                .font(SettingsType.title)
                .foregroundStyle(tint)
            Spacer(minLength: 10)
            if let value {
                Text(value)
                    .font(SettingsType.value)
                    .foregroundStyle(SettingsType.valueColor)
                    .lineLimit(1)
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.tertiaryLabel)
            }
        }
        .frame(minHeight: SettingsType.rowHeight)
        .contentShape(Rectangle())
    }
}

/// Settings type: bold is for the page title only. A row's title is
/// medium, so the list breathes; a value is regular, in a grey dark enough
/// to read without competing with the title.
enum SettingsType {
    static let title = Typography.font(16.5, weight: .medium)
    static let value = Typography.font(15, weight: .regular)
    static let valueColor = Color(light: "5F6B7A", dark: "A1A1AA")
    /// Apple's list rhythm: 52pt rows on a 4pt grid.
    static let rowHeight: CGFloat = 52
}

/// "Upgrade your account" for the free plan, one row with an aura: Evlin's
/// leaf on a green tile in a breathing green and lime glow with sparkles
/// twinkling round it, a shine across the title now and then, and under
/// it a line that turns through what Pro gives you. Opens the plan page.
/// Reduce Motion: the glow and the first line, still. Also at the top of
/// Profile on the free plan (2026-11-17).
struct UpgradeAccountRow: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var glow = false
    @State private var line = 0
    @State private var shine: CGFloat = -1

    private static let lines = [
        "Repeat tasks automatically",
        "Daily downtime, on your schedule",
        "Apps lock at bedtime",
        "Less nagging, more routine",
    ]
    private static let green = Color(light: "1E9E48", dark: "4CAF6A")

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                aura
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade your account")
                        .font(SettingsType.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(Self.green)
                        .overlay {
                            // The shine: a light band passing over the words.
                            GeometryReader { geo in
                                LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: geo.size.width * 0.45)
                                    .offset(x: shine * geo.size.width)
                            }
                            .mask(Text("Upgrade your account").font(SettingsType.title))
                            .allowsHitTesting(false)
                        }
                    Text(Self.lines[line])
                        .font(Typography.font(13, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(SettingsType.valueColor)
                        .id(line)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                                                removal: .opacity.combined(with: .offset(y: -4))))
                }
                Spacer(minLength: 10)
                Text("Pro")
                    .font(Typography.font(12.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(EvlinPlan.gradient, in: Capsule())
                    .shadow(color: EvlinPlan.accent.opacity(glow ? 0.55 : 0.15), radius: glow ? 8 : 3)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StatusCardStyle.tertiaryLabel)
            }
            .frame(minHeight: SettingsType.rowHeight + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTapStyle())
        .accessibilityLabel("Upgrade your account to Evlin Pro")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
        }
        // Every few seconds the next thing Pro gives, with a shine across
        // the title. Stops when the row goes off screen.
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_400_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.35)) { line = (line + 1) % Self.lines.count }
                shine = -1
                withAnimation(.easeInOut(duration: 0.9)) { shine = 1.2 }
            }
        }
    }

    // The tile in its aura: two soft glows breathing out of step, and three
    // sparkles that brighten with them.
    // The glows are half as strong in Dark, where they'd blaze on the page.
    private var dim: Double { colorScheme == .dark ? 0.45 : 1 }

    private var aura: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "B9F04F"))
                .frame(width: 50, height: 50)
                .blur(radius: 14)
                .opacity((glow ? 0.25 : 0.55) * dim)
                .scaleEffect(glow ? 0.9 : 1.25)
            Circle()
                .fill(EvlinPlan.accent)
                .frame(width: 44, height: 44)
                .blur(radius: 10)
                .opacity((glow ? 0.65 : 0.25) * dim)
                .scaleEffect(glow ? 1.25 : 0.9)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(EvlinPlan.gradient)
                .frame(width: 30, height: 30)
                .shadow(color: EvlinPlan.accent.opacity(0.4), radius: 4, y: 1)
            FlameLeaf()
                .fill(Color.white)
                .frame(width: 13, height: 17)
            sparkle(size: 8, x: 17, y: -16, bright: glow)
            sparkle(size: 6, x: -18, y: -10, bright: !glow)
            sparkle(size: 5, x: 16, y: 15, bright: !glow)
        }
        .frame(width: 30, height: 30)
    }

    private func sparkle(size: CGFloat, x: CGFloat, y: CGFloat, bright: Bool) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Color(hex: "7FD65A"))
            .opacity(bright ? 1 : 0.15)
            .scaleEffect(bright ? 1 : 0.5)
            .offset(x: x, y: y)
    }
}

/// The line between two groups of rows; rows within a group have none.
private struct SettingsGroupGap: View {
    var body: some View {
        Rectangle().fill(HomeStyle.line).frame(height: 1).padding(.vertical, 10)
    }
}

/// The Settings rows, one under another.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
    }
}


/// Each Settings row's colour, the way iOS Settings tells rows apart at a
/// glance. Screen time is Apple's Screen Time purple.
enum SettingsTile {
    static let account = Color(hex: "0A84FF")
    static let plan = Color(hex: "3FCE64")
    static let children = Color(hex: "FF9500")
    static let addChild = Color(hex: "30B0C7")
    static let notifications = Color(hex: "FF3B30")
    static let screenTime = Color(hex: "5856D6")
    static let accessCode = Color(hex: "F59E0B")
    static let report = Color(hex: "8E8E93")
    static let invite = Color(hex: "FF2D55")
    static let privacy = Color(hex: "0A84FF")
    static let appearance = Color(hex: "5856D6")   // indigo: reads on both pages
}

/// A white icon on a small coloured rounded square.
struct SettingsTileIcon: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}

/// The hairline between groups of rows.
private struct ManageDivider: View {
    var body: some View {
        Rectangle().fill(HomeStyle.line).frame(height: 1).padding(.vertical, 10)
    }
}

private struct ChildSettingsSheet: View {
    @ObservedObject var child: Child
    var onRemoved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showUnpairConfirm = false
    @State private var showRemoveConfirm = false
    @State private var showPairing = false
    @State private var showDevicePage = false
    @State private var nameOnOpen = ""
    // Screen time (the limit, downtime, custom rules) isn't here: it lives
    // on ChildScreenTimeSheet, opened from the child's card on Home, next to
    // the time left. This page is the child's identity and device: name,
    // picture, and a Device row that opens the device page (Unpair or Pair,
    // and removing the profile at the end).

    var body: some View {
        NavigationStack {
            profilePage
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showDevicePage) { devicePage }
        }
        .sheet(isPresented: $showUnpairConfirm) {
            Group {
            DestructiveConfirmSheet(
                title: "Unpair \(child.name)'s device?",
                consequences: [
                    "Apps unlock immediately.",
                    "Nothing is enforced until a device is paired again.",
                    "Tasks and history are kept.",
                ],
                destructiveLabel: "Unpair Device",
                onConfirm: {
                    if let id = child.devices.first?.id {
                        FamilyStore.removeDevice(id, from: child.id)
                    }
                    Outbox.send(APIClient.Write.unpairDevice(childId: child.id), label: "Unpairing the device")
                    showUnpairConfirm = false
                },
                onCancel: { showUnpairConfirm = false }
            )
        }
            .presentationDragIndicator(.visible)
        }
        .onAppear { nameOnOpen = child.name }
        .onDisappear {
            // The field edits the local Child live; persist it once the sheet
            // closes, otherwise the next backend sync would put the old name
            // back. (A removed child no longer exists locally: skip.)
            let newName = child.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard newName != nameOnOpen, !newName.isEmpty,
                  FamilyStore.children.contains(where: { $0.id == child.id }) else { return }
            Outbox.send(APIClient.Write.updateChild(childId: child.id, name: newName), childId: child.id, label: "The new name")
        }
        .sheet(isPresented: $showRemoveConfirm) {
            Group {
            DestructiveConfirmSheet(
                title: "Delete \(child.name)'s account?",
                consequences: [
                    "Tasks, history, and settings are deleted.",
                    "The device is unpaired and apps unlock.",
                    "This can't be undone.",
                ],
                destructiveLabel: "Delete \(child.name)'s Account",
                onConfirm: {
                    let removedId = child.id
                    FamilyStore.removeChild(removedId)
                    // If the backend refuses, the sync after it brings the
                    // child back, which is the honest outcome.
                    Outbox.send(APIClient.Write.deleteChild(childId: removedId), label: "Removing the profile")
                    showRemoveConfirm = false
                    dismiss()
                    onRemoved()
                },
                onCancel: { showRemoveConfirm = false }
            )
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPairing) {
            Group {
            PairingSheet(child: child)
        }
            .presentationDragIndicator(.visible)
        }
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 12)

                Button("Done") { dismiss() }
                    .buttonStyle(SettingsTapStyle())
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    .frame(minHeight: 48, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            VStack(spacing: 14) {
                childAvatar
                Text(child.name)
                    .font(Typography.font(28, weight: .heavy))
                    .foregroundStyle(FormGreen.title)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            .padding(.bottom, 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    FormField(label: "Name") {
                        FormTextField(placeholder: "Child's name", text: $child.name)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ManageRow(icon: child.devices.isEmpty ? "iphone.slash" : "iphone",
                                  title: "Device",
                                  value: child.devices.first?.name ?? "Not paired") {
                            showDevicePage = true
                        }
                    }

                    // At the end of the child's own page, as Delete account is
                    // on the parent's.
                    VStack(alignment: .leading, spacing: 0) {
                        ManageDivider()
                        ManageRow(icon: "trash", title: "Delete \(child.name)'s account", tint: EColor.danger, showChevron: false) {
                            showRemoveConfirm = true
                        }
                        Text("Deletes their tasks and history for good, and unpairs their device.")
                            .font(Typography.font(12, weight: .regular))
                            .foregroundStyle(Color(.secondaryLabel))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .dismissKeyboardOnTap()
            .scrollDismissesKeyboard(.interactively)
        }
        .background(EColor.surface)
    }

    /// The device: what's paired, and Unpair (or Pair).
    private var devicePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceRow

            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(EColor.surface)
        .navigationTitle("\(child.name)'s device")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var childAvatar: some View {
        Circle().fill(child.color)
            .overlay(Text(String(child.name.prefix(1))).font(Typography.font(38, weight: .bold)).foregroundStyle(.white))
            .frame(width: 104, height: 104)
    }

    // Switches on device state — paired shows the device and a red
    // Unpair; unpaired shows "No device" and a green Pair, which is what
    // actually opens the QR/code pairing sheet.
    @ViewBuilder
    private var deviceRow: some View {
        if let device = child.devices.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    deviceIconChip("iphone")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(Typography.font(15, weight: .semibold)).foregroundStyle(FormGreen.title)
                        Text("Paired \(device.pairedOn)").font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                }
                Button(role: .destructive) { showUnpairConfirm = true } label: {
                    Text("Unpair")
                        .font(Typography.font(14, weight: .bold))
                        .foregroundStyle(EColor.onDangerFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(EColor.dangerFill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SettingsTapStyle())
            }
            .padding(16)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    deviceIconChip("iphone.slash")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No device").font(Typography.font(15, weight: .semibold)).foregroundStyle(FormGreen.title)
                        Text("Nothing is enforced until a device is paired").font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                }
                Button { showPairing = true } label: {
                    Text("Pair")
                        .font(Typography.font(14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(FormGreen.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SettingsTapStyle())
            }
            .padding(16)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func deviceIconChip(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(FormGreen.accent)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FormGreen.accentBg))
    }
}

// MARK: - Child screen time

// The child's screen time controls: the daily limit, downtime, and custom
// rules. Opened from the child's card on Home, where the time left is
// shown, rather than buried in Settings. The rows, toggles and edit sheets
// are the ones that used to sit on the child's Settings page, unchanged.
struct ChildScreenTimeSheet: View {
    @ObservedObject var child: Child

    @Environment(\.dismiss) private var dismiss

    @State private var editingRule: ChildRule?
    @State private var editingScreenTimeLimit = false
    @State private var addingBlockedApps = false

    var body: some View {
        // The blocked apps list reads the sync cache; this redraws it on each sync.
        let _ = SyncState.shared.version
        NavigationStack {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text("\(child.name)'s screen time")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    screenTimeSection

                    downtimeSection

                    blockedAppsSection
                }
                .padding(.horizontal, 20)
            }
        }
        .background(EColor.surface)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { blockId in
            BlockedAppDetail(blockId: blockId, child: child)
        }
        .navigationDestination(for: AllBlockedApps.self) { _ in
            AllBlockedAppsPage(child: child)
        }
        }
        .sheet(item: $editingRule) { rule in
            Group {
            EditRuleSheet(rule: rule, onSave: { updated in
                child.saveRule(updated)
                editingRule = nil
            }, onCancel: { editingRule = nil }, onDelete: {
                editingRule = nil
                child.deleteRule(rule)
            })
        }
            .closesOnlyWithButton()
        }
        .sheet(isPresented: $addingBlockedApps) {
            AddBlockedAppsSheet(child: child) { addingBlockedApps = false }
                .presentationDragIndicator(.visible)   // held once apps are picked (FormShell)
        }
        .sheet(isPresented: $editingScreenTimeLimit) {
            Group {
            EditScreenTimeLimitSheet(
                childName: child.name,
                daily: child.dailyLimitMin,
                weekly: child.weeklySchedule,
                onSave: { daily, weekly in
                    child.saveScreenTimeLimit(daily: daily, weekly: weekly)
                    editingScreenTimeLimit = false
                },
                onCancel: { editingScreenTimeLimit = false }
            )
        }
            .presentationDragIndicator(.visible)   // swipes away; held when there are changes (FormShell)
        }
    }

    // MARK: - Screen time

    private var dailyLimitRule: ChildRule? { child.rules.first { $0.kind == .screenTimeLimit } }
    private var downtimeRule: ChildRule? { child.rules.first { $0.kind == .downtime } }

    private static let limitGreen = Color(hex: "34C759")

    // The limit as a row, sized like Settings' own rows: what it is, the
    // amount under it, and when the days differ, the week as small bars
    // with today's in full colour. The whole card opens the editor.
    private var screenTimeSection: some View {
        let week = ScreenTimeSchedule.minutes(daily: child.dailyLimitMin, weekly: child.weeklySchedule)
        let today = ScreenTimeSchedule.todayIndex
        let varies = Set(week).count > 1
        return Button { editingScreenTimeLimit = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    cardIcon("hourglass", tint: Self.limitGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen time")
                            .font(Typography.font(15.5, weight: .semibold))
                            .foregroundStyle(EColor.onSurface)
                        Text(varies ? "\(ScreenTimeSchedule.limitText(week[today])) today · Custom days"
                                    : "\(ScreenTimeSchedule.limitText(week[0])) every day")
                            .font(Typography.font(13.5, weight: .regular))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    cardChevron
                }
                if varies {
                    WeekLimitBars(minutes: week, highlighted: today, tint: Self.limitGreen)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(CardPressStyle(haptic: true))
        .accessibilityLabel("Daily limit, \(ScreenTimeSchedule.summary(daily: child.dailyLimitMin, weekly: child.weeklySchedule))")
    }

    // Downtime as a row: its hours and days under the name, with its
    // switch; the rest of the row edits it. Before it's set up: what it is,
    // with a small "Set up" pill.
    @ViewBuilder private var downtimeSection: some View {
        if let rule = downtimeRule {
            HStack(spacing: 12) {
                Button { editingRule = rule } label: {
                    HStack(spacing: 12) {
                        cardIcon("moon.fill", tint: downtimeIndigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downtime")
                                .font(Typography.font(15.5, weight: .semibold))
                                .foregroundStyle(EColor.onSurface)
                            Text(rule.downtimeHours.isEmpty
                                 ? "\(ChildRule.fmtClock(rule.downtimeFrom)) – \(ChildRule.fmtClock(rule.downtimeTo))"
                                 : "Hours vary by day")
                                .font(Typography.font(13.5, weight: .regular))
                                .foregroundStyle(EColor.onSurfaceVariant)
                            Text(ScreenTimeSchedule.daysText(rule.downtimeDays))
                                .font(Typography.font(13.5, weight: .regular))
                                .foregroundStyle(EColor.onSurfaceVariant)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPressStyle(haptic: true))
                .accessibilityLabel("Downtime, \(rule.detail), \(ScreenTimeSchedule.daysText(rule.downtimeDays))")
                .accessibilityHint("Edits the hours and days")
                EToggle(on: Binding(
                    get: { rule.on },
                    set: { newValue in
                        guard let i = child.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                        child.rules[i].on = newValue
                        if !newValue { child.endDowntimeNowIfActive() }
                        child.pushRules()
                    }
                ), color: downtimeIndigo)
            }
            .padding(14)
            .background(FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Button {
                editingRule = Child.newDowntimeRule()
            } label: {
                HStack(spacing: 12) {
                    cardIcon("moon.fill", tint: downtimeIndigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downtime").font(Typography.font(15.5, weight: .semibold)).foregroundStyle(EColor.onSurface)
                        Text("A break each night")
                            .font(Typography.font(13.5, weight: .regular))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }
                    Spacer(minLength: 8)
                    Text("Set up")
                        .font(Typography.font(13.5, weight: .semibold))
                        .foregroundStyle(downtimeIndigo)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(downtimeIndigo.opacity(0.1), in: Capsule())
                }
                .padding(14)
                .background(FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(CardPressStyle(haptic: true))
        }
    }

    // A white glyph on a coloured rounded square, the size of Settings'.
    private func cardIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cardChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(.tertiaryLabel))
    }

}

// The screen time edits, shared by the Screen time sheet and the Profile tab.
extension Child {
    func saveRule(_ updated: ChildRule) {
        if let i = rules.firstIndex(where: { $0.id == updated.id }) {
            rules[i] = updated
        } else {
            rules.append(updated)   // a downtime set up just now
        }
        pushRules()
    }

    func deleteRule(_ rule: ChildRule) {
        rules.removeAll { $0.id == rule.id }
        if rule.kind == .downtime { endDowntimeNowIfActive() }
        pushRules()
    }

    func saveScreenTimeLimit(daily: Int, weekly: [String: Int]) {
        dailyLimitMin = daily
        weeklySchedule = weekly
        if let i = rules.firstIndex(where: { $0.kind == .screenTimeLimit }) {
            rules[i].detail = ScreenTimeSchedule.summary(daily: daily, weekly: weekly)
        }
        pushRules()
    }

    /// A downtime about to start, as Profile's and the sheet's "Set up" open it.
    static func newDowntimeRule() -> ChildRule {
        var rule = ChildRule(id: "downtime", kind: .downtime, icon: "dark_mode", title: "Downtime", detail: "", on: true)
        rule.detail = "\(ChildRule.fmtClock(rule.downtimeFrom)) – \(ChildRule.fmtClock(rule.downtimeTo))"
        return rule
    }

    // Downtime is a schedule lock — turning the rule off (or deleting it)
    // while it's actively in effect needs to actually end the lock right
    // now, not just stop applying the *next* time downtime would start.
    func endDowntimeNowIfActive() {
        guard status == .downtime else { return }
        manualLock = false
        taskGateOverride = true
        timeLeft = formatMinutes(dailyLimitMin)
        timePct = 100
        downtimeUntil = nil
        saveState(label: "Unlocking the phone")
    }
}

// Blocked apps: a list on the Screen time page; each app opens its own
// page with why and when it's blocked, and Lift.
extension ChildScreenTimeSheet {
    /// Blocks still in force for a child — blocking now, or scheduled and
    /// waiting for their hours. From the sync cache.
    static func blocksInForce(childId: String) -> [CachedAppBlock] {
        LocalStore.shared.cachedAppBlocks(childId: childId).filter { block in
            guard !block.resolved else { return false }
            if block.blockType == "duration", let endsAt = block.endsAt { return Date() < endsAt }
            return block.state == nil || block.state == "active" || block.state == "off_window"
        }
        .sorted { $0.appName < $1.appName }
    }

    var blocksInForce: [CachedAppBlock] { Self.blocksInForce(childId: child.id) }

    /// One row per app: an app blocked twice (say, for an hour and until
    /// lifted) is still one blocked app. The row shows the block that lasts
    /// longest.
    var blockedApps: [CachedAppBlock] { Self.blockedApps(childId: child.id) }

    static func blockedApps(childId: String) -> [CachedAppBlock] {
        Dictionary(grouping: blocksInForce(childId: childId), by: { $0.appName })
            .values
            .compactMap { group in group.max { BlockedAppDetail.lasting($0) < BlockedAppDetail.lasting($1) } }
            .sorted { $0.appName < $1.appName }
    }

    private static let blockedRed = Color(hex: "E5484D")
    /// Apps listed on the card before "Show all".
    static let shownBlockedApps = 3

    /// Always shown, so a parent sees that apps can be paused from here: a
    /// set time, the rest of the day, or until they allow it again. Empty,
    /// it reads like the downtime row's invitation; with apps, it lists them.
    var blockedAppsSection: some View {
        let apps = blockedApps
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { addingBlockedApps = true } label: {
                    HStack(spacing: 12) {
                        cardIcon("nosign", tint: Self.blockedRed)
                        Text("Blocked apps")
                            .font(Typography.font(15.5, weight: .semibold))
                            .foregroundStyle(EColor.onSurface)
                        Spacer(minLength: 8)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPressStyle(haptic: true))
                .accessibilityLabel(apps.isEmpty ? "Blocked apps, none" : "Blocked apps, \(apps.count)")
                .accessibilityHint("Adds an app to block")

                ForEach(apps.prefix(Self.shownBlockedApps), id: \.id) { block in
                    Divider().padding(.leading, 56)
                    BlockedAppRow(block: block)
                }
            }
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // More than fit on the card: the rest are a tap away, on a page of
            // their own that scrolls. Plain and centred under the card, the
            // same "Show all N" as the family list in Settings.
            if apps.count > Self.shownBlockedApps {
                NavigationLink(value: AllBlockedApps()) {
                    Text("Show all \(apps.count)")
                        .font(Typography.font(15, weight: .semibold))
                        .foregroundStyle(EColor.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsTapStyle())
                .padding(.top, 6)
            }
        }
    }
}

/// Marks the "Show all" page in the screen time sheet's navigation.
struct AllBlockedApps: Hashable {}

/// One blocked app as a row: its icon, name, and until when. Opens its page.
struct BlockedAppRow: View {
    let block: CachedAppBlock

    var body: some View {
        NavigationLink(value: block.id) {
            HStack(spacing: 12) {
                AppIconView(appName: block.appName, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.appName).font(Typography.font(15.5, weight: .semibold)).foregroundStyle(EColor.onSurface)
                    Text(BlockedAppDetail.when(block))
                        .font(Typography.font(13.5, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTapStyle())
    }
}

/// Every blocked app for a child, when there are more than the card shows.
struct AllBlockedAppsPage: View {
    @ObservedObject var child: Child
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = SyncState.shared.version
        let apps = ChildScreenTimeSheet.blockedApps(childId: child.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsTapStyle())
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text("Blocked apps")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { i, block in
                        if i > 0 { Divider().padding(.leading, 56) }
                        BlockedAppRow(block: block)
                    }
                }
                .background(FormGreen.fieldBg)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(EColor.surface)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// One blocked app: what it is, whether it's blocked right now, why and
/// until when, and Lift.
struct BlockedAppDetail: View {
    var blockId: String
    var child: Child
    @Environment(\.dismiss) private var dismiss

    private var block: CachedAppBlock? {
        LocalStore.shared.cachedAppBlocks(childId: child.id).first { $0.id == blockId }
    }

    /// How long a block holds, for choosing which one an app's row shows:
    /// one that waits on the parent outlasts any with an end time.
    static func lasting(_ block: CachedAppBlock) -> Date {
        if block.blockType == "duration", let end = block.endsAt { return end }
        return .distantFuture
    }

    /// Every block on this app still in force: Lift ends them all, or the
    /// app would stay blocked by the one the row didn't show.
    private var sameApp: [CachedAppBlock] {
        guard let block else { return [] }
        return ChildScreenTimeSheet.blocksInForce(childId: child.id)
            .filter { $0.appName == block.appName }
    }

    /// Made on this phone and not yet on the server, so it has no id
    /// there to lift yet. (The Demo build never sends, so it lifts locally.)
    private var unsent: Bool { !DemoMode.isBuild && sameApp.contains { $0.id.hasPrefix("local-") } }

    /// Why and until when, in the server's own words where it has them.
    static func when(_ block: CachedAppBlock) -> String {
        if block.blockType == "duration", let end = block.endsAt {
            return "Until \(ChildRule.fmtClock(end))"
        }
        // Said here rather than taken from the server, which said "until
        // you lift it" before this wording.
        if block.blockType == "indefinite" { return "Always" }
        if let summary = block.summary, !summary.isEmpty {
            return summary.prefix(1).uppercased() + summary.dropFirst()
        }
        switch block.blockType {
        case "until_task": return "Until a task is approved"
        case "scheduled": return "On a schedule"
        default: return "Always"
        }
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsTapStyle())
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            if let block {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 14) {
                            AppIconView(appName: block.appName, size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.appName)
                                    .font(Typography.font(24, weight: .heavy))
                                    .foregroundStyle(FormGreen.title)
                                Text(block.state == "off_window" ? "Not blocked right now" : "Blocked now")
                                    .font(Typography.font(14, weight: .semibold))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                        // One row: blocked until when (2026-11-09; "Blocked: For
                        // a set time" over "When: Until 5:06 PM" said it twice).
                        detailRow("Blocked", Self.when(block))
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                Button {
                    for b in sameApp {
                        LocalStore.shared.mirrorBlockLifted(id: b.id)
                        if !b.id.hasPrefix("local-") {
                            Outbox.send(APIClient.Write.liftAppBlock(blockId: b.id), childId: child.id, label: "Lifting that block")
                        }
                    }
                    SyncState.shared.version += 1
                    dismiss()
                } label: {
                    Text(unsent ? "Saving…" : "Lift block")
                        .font(Typography.font(16, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Brand.greenDeep, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressedFadeStyle())
                .disabled(unsent)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else {
                Spacer()
            }
        }
        .background(EColor.surface)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.font(14, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
            Spacer(minLength: 12)
            Text(value).font(Typography.font(14, weight: .bold)).foregroundStyle(EColor.onSurface)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

// MARK: - Screen Time edit sheets (used by ChildScreenTimeSheet above)

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
}

private func ruleTimeField(label: String?, date: Binding<Date>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        if let label {
            Text(label).font(Typography.font(11, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
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

struct EditRuleSheet: View {
    @State var rule: ChildRule
    var onSave: (ChildRule) -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var showDeleteConfirm = false
    /// Downtime set day by day (Customize Days): which days, and each
    /// day's own hours, as the screen-time limit is (2026-11-08).
    @State private var customDays = false
    /// The day whose hours are open (Customize Days).
    @State private var openDay: Int?

    init(rule: ChildRule, onSave: @escaping (ChildRule) -> Void, onCancel: @escaping () -> Void, onDelete: (() -> Void)? = nil) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _customDays = State(initialValue: (!rule.downtimeDays.isEmpty && rule.downtimeDays.count < 7) || !rule.downtimeHours.isEmpty)
    }

    /// Downtime as it would be saved: Every Day is one set of hours; days
    /// set one by one keep their own hours only when they differ.
    private func downtimeToSave(_ rule: ChildRule) -> ChildRule {
        var r = rule
        guard customDays else {
            r.downtimeDays = []
            r.downtimeHours = [:]
            return r
        }
        let on = ScreenTimeSchedule.days.filter { r.downtimeDays.contains($0) }
        let spans = on.map { r.downtimeSpan(on: $0) }
        if let first = spans.first {
            r.downtimeFrom = first.from
            r.downtimeTo = first.to
        }
        if Set(spans.map(\.minutes)).count <= 1 {
            r.downtimeHours = [:]
        } else {
            r.downtimeHours = Dictionary(uniqueKeysWithValues: zip(on, spans))
        }
        if on.count == 7 { r.downtimeDays = [] }   // every day
        return r
    }

    var body: some View {
        FormShell(title: rule.kind == .custom ? "Edit Rule" : RuleTypeMeta.label(rule.kind), onCancel: onCancel, onSave: {
            var updated = rule
            if updated.kind == .downtime {
                updated = downtimeToSave(updated)
                updated.detail = "\(ChildRule.fmtClock(updated.downtimeFrom)) – \(ChildRule.fmtClock(updated.downtimeTo))"
            }
            onSave(updated)
        }, canSave: !rule.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !(rule.kind == .downtime && customDays && rule.downtimeDays.isEmpty), onDelete: onDelete != nil ? { showDeleteConfirm = true } : nil, deleteTitle: "Delete rule") {
            switch rule.kind {
            case .downtime:
                // As the screen-time limit asks it: Every Day (one set of
                // hours) or Customize Days (a row per day with its hours or
                // Off; a tap opens its switch and hours under it).
                // Customize Days needs the server to store each day's
                // downtime (ServerSupport.downtimeByDay).
                if ServerSupport.downtimeByDay {
                    EveryDayOrCustom(custom: $customDays)
                        .padding(.bottom, 18)
                }
                if customDays && ServerSupport.downtimeByDay {
                    FormField(label: "Each day's downtime") {
                        VStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { i in
                                if i > 0 { Divider().padding(.leading, 16) }
                                downtimeDayRow(i)
                                if openDay == i { downtimeDayHours(i).transition(.opacity) }
                            }
                        }
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .transition(.opacity)
                } else {
                    HStack(spacing: 12) {
                        ruleTimeField(label: "from", date: $rule.downtimeFrom)
                        ruleTimeField(label: "to", date: $rule.downtimeTo)
                    }
                    .padding(.bottom, 18)
                    .transition(.opacity)
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
                // Unreachable in practice — the Screen Time row always opens
                // EditDailyScreenTimeLimitSheet instead — kept only so the
                // switch stays exhaustive.
                EmptyView()
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: customDays)
        .animation(.spring(duration: 0.3, bounce: 0), value: openDay)
        .onChange(of: customDays) { _, isCustom in
            openDay = nil
            // Customising starts from every day, each with the hours set so
            // far, to change or switch off.
            guard isCustom, rule.kind == .downtime else { return }
            if rule.downtimeDays.isEmpty { rule.downtimeDays = Set(ScreenTimeSchedule.days) }
            for code in ScreenTimeSchedule.days where rule.downtimeHours[code] == nil {
                rule.downtimeHours[code] = DowntimeHours(from: rule.downtimeFrom, to: rule.downtimeTo)
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

    /// A day: its name and its hours ("8 PM – 7 AM") or Off; a tap opens it.
    private func downtimeDayRow(_ i: Int) -> some View {
        let code = ScreenTimeSchedule.days[i]
        let on = rule.downtimeDays.contains(code)
        let span = rule.downtimeSpan(on: code)
        return Button { openDay = openDay == i ? nil : i } label: {
            HStack {
                Text(ScreenTimeSchedule.names[i]).font(Typography.font(15.5, weight: .regular)).foregroundStyle(EColor.onSurface)
                Spacer()
                Text(on ? "\(shortClock(span.from)) – \(shortClock(span.to))" : "Off")
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(openDay == i ? FormGreen.accent : EColor.onSurfaceVariant)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .rotationEffect(.degrees(openDay == i ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTapStyle())
        .accessibilityValue(on ? "\(ChildRule.fmtClock(span.from)) to \(ChildRule.fmtClock(span.to))" : "Off")
    }

    /// An open day: downtime on or off that day, and its hours.
    private func downtimeDayHours(_ i: Int) -> some View {
        let code = ScreenTimeSchedule.days[i]
        let on = Binding(
            get: { rule.downtimeDays.contains(code) },
            set: { if $0 { rule.downtimeDays.insert(code) } else { rule.downtimeDays.remove(code) } })
        let from = Binding(
            get: { rule.downtimeSpan(on: code).from },
            set: { rule.downtimeHours[code] = DowntimeHours(from: $0, to: rule.downtimeSpan(on: code).to) })
        let to = Binding(
            get: { rule.downtimeSpan(on: code).to },
            set: { rule.downtimeHours[code] = DowntimeHours(from: rule.downtimeSpan(on: code).from, to: $0) })
        return VStack(spacing: 12) {
            HStack {
                Text("Downtime on \(ScreenTimeSchedule.names[i])")
                    .font(Typography.font(14.5, weight: .medium))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
                EToggle(on: on, color: FormGreen.accent)
                    .accessibilityLabel("Downtime on \(ScreenTimeSchedule.names[i])")
            }
            if on.wrappedValue {
                HStack(spacing: 12) {
                    ruleTimeField(label: "from", date: from)
                    ruleTimeField(label: "to", date: to)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .sensoryFeedback(.selection, trigger: on.wrappedValue)
    }

    /// "8 PM", or "8:30 PM" when it isn't on the hour.
    private func shortClock(_ date: Date) -> String {
        ChildRule.fmtClock(date).replacingOccurrences(of: ":00", with: "")
    }
}

// The screen-time limit, set as iOS's own Screen Time sets it: Every Day
// (one amount, on the scrolling wheel) or Customize Days (a row per day;
// tapping one opens its own wheel under it). Nothing saves until Save.
struct EditScreenTimeLimitSheet: View {
    var childName: String
    var onSave: (_ daily: Int, _ weekly: [String: Int]) -> Void
    var onCancel: () -> Void

    @State private var custom: Bool
    @State private var everyDay: Int
    @State private var perDay: [Int]
    /// The day whose wheel is open (Customize Days).
    @State private var openDay: Int?

    init(childName: String, daily: Int, weekly: [String: Int],
         onSave: @escaping (_ daily: Int, _ weekly: [String: Int]) -> Void, onCancel: @escaping () -> Void) {
        self.childName = childName
        self.onSave = onSave
        self.onCancel = onCancel
        let week = ScreenTimeSchedule.minutes(daily: daily, weekly: weekly)
        _custom = State(initialValue: Set(week).count > 1)
        _everyDay = State(initialValue: max(15, week[ScreenTimeSchedule.todayIndex]))
        _perDay = State(initialValue: week)
    }

    /// The week as it would be saved, Monday first.
    private var week: [Int] { custom ? perDay : Array(repeating: everyDay, count: 7) }

    private func save() {
        let w = week
        if Set(w).count == 1 {
            onSave(w[0], [:])
        } else {
            onSave(w[0], Dictionary(uniqueKeysWithValues: zip(ScreenTimeSchedule.days, w)))
        }
    }

    // The general guideline: over ~2 hours of recreational screen time a
    // day is worth a second look, over 3 worth a flag. Not a block, just
    // something to see before saving.
    private var warning: (color: Color, icon: String, text: String)? {
        let most = week.max() ?? 0
        let when = Set(week).count == 1 ? "a day" : "on some days"
        if most >= 180 {
            return (EColor.danger, "exclamationmark.octagon.fill",
                    "\(formatMinutes(most)) \(when) is above the general guideline. Long screen time is linked to worse sleep, mood and attention in children.")
        }
        if most >= 135 {
            return (Color(hex: "B26A00"), "exclamationmark.triangle.fill",
                    "\(formatMinutes(most)) \(when) is at the upper end of the general screen-time guideline for kids.")
        }
        return nil
    }

    var body: some View {
        FormShell(title: "Screen Time Limit", onCancel: onCancel, onSave: save,
                  canSave: week.contains { $0 > 0 }, saveLabel: "Save limit") {
            EveryDayOrCustom(custom: $custom)
                .padding(.bottom, 18)

            if custom {
                FormField(label: "Each day's limit") {
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            if i > 0 { Divider().padding(.leading, 16) }
                            dayRow(i)
                            if openDay == i {
                                LimitWheel(minutes: $perDay[i], least: 0)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else {
                FormField(label: "Daily limit") {
                    LimitWheel(minutes: $everyDay, least: 15)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            // No animation: the wheel changes the amount many times a
            // second, and a cross-fade would lag behind it.
            if let warning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: warning.icon).foregroundStyle(warning.color)
                    Text(warning.text).font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurface)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(warning.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transaction { $0.animation = nil }
                .padding(.bottom, 12)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: custom)
        .animation(.spring(duration: 0.3, bounce: 0), value: openDay)
        .onChange(of: custom) { _, isCustom in
            // Customising starts from the one amount set so far.
            if isCustom && Set(perDay).count == 1 { perDay = Array(repeating: everyDay, count: 7) }
            openDay = nil
        }
    }

    private func dayRow(_ i: Int) -> some View {
        Button { openDay = openDay == i ? nil : i } label: {
            HStack {
                Text(ScreenTimeSchedule.names[i])
                    .font(Typography.font(15.5, weight: .regular))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
                Text(ScreenTimeSchedule.limitText(perDay[i]))
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(openDay == i ? FormGreen.accent : EColor.onSurfaceVariant)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .rotationEffect(.degrees(openDay == i ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTapStyle())
    }
}

/// "Every Day" or "Customize Days", as iOS's Screen Time asks it: two rows,
/// a check beside the chosen one.
struct EveryDayOrCustom: View {
    @Binding var custom: Bool

    var body: some View {
        VStack(spacing: 0) {
            row("Every Day", chosen: !custom) { custom = false }
            Divider().padding(.leading, 16)
            row("Customize Days", chosen: custom) { custom = true }
        }
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.selection, trigger: custom)
    }

    private func row(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Typography.font(15.5, weight: .regular)).foregroundStyle(EColor.onSurface)
                Spacer()
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FormGreen.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The amount on a scrolling wheel, in 15-minute steps up to 8 hours
/// (from "None" when `least` is 0). Built on a scroll view rather than a
/// wheel Picker: a Picker only reports where it stopped, so anything shown
/// from the amount (the guideline warning) lagged behind a fast flick.
private struct LimitWheel: View {
    @Binding var minutes: Int
    var least: Int

    @State private var scrollID: Int?

    private var options: [Int] { Array(stride(from: least, through: 480, by: 15)) }
    private let itemHeight: CGFloat = 44
    private let visibleRows: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let inset = max(0, (geo.size.height - itemHeight) / 2)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { m in
                        Text(ScreenTimeSchedule.limitText(m))
                            .font(Typography.font(m == minutes ? 17 : 15, weight: m == minutes ? .semibold : .regular))
                            .foregroundStyle(m == minutes ? EColor.onSurface : EColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .frame(height: itemHeight)
                            .id(m)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollID)
            .contentMargins(.vertical, inset, for: .scrollContent)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.05))
                    .frame(height: itemHeight - 6)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: itemHeight * visibleRows)
        .onAppear { scrollID = options.contains(minutes) ? minutes : options.first }
        .onChange(of: scrollID) { _, value in
            if let value, value != minutes { minutes = value }
        }
        .sensoryFeedback(.selection, trigger: minutes)
        .accessibilityElement()
        .accessibilityLabel(ScreenTimeSchedule.limitText(minutes))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(480, minutes + 15)
            case .decrement: minutes = max(least, minutes - 15)
            @unknown default: break
            }
            scrollID = minutes
        }
    }
}

/// The week's limits as seven small bars, Monday first, the highlighted
/// day (today) in full colour.
struct WeekLimitBars: View {
    var minutes: [Int]
    var highlighted: Int
    var tint: Color

    var body: some View {
        let top = max(minutes.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(i == highlighted ? tint : tint.opacity(0.28))
                        .frame(width: 14, height: minutes[i] > 0 ? max(6, 40 * CGFloat(minutes[i]) / CGFloat(top)) : 4)
                        .frame(height: 40, alignment: .bottom)
                    Text(ScreenTimeSchedule.letters[i])
                        .font(Typography.font(11, weight: i == highlighted ? .bold : .semibold))
                        .foregroundStyle(i == highlighted ? EColor.onSurface : EColor.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: minutes)
        .accessibilityHidden(true)
    }
}

/// A card that sinks a little while pressed.
struct CardPressStyle: ButtonStyle {
    /// A light tap felt as it's pressed (Settings' buttons, 2026-11-09).
    var haptic = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.18, bounce: 0), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if haptic && pressed { TapHaptic.play() }
            }
    }
}

/// Settings' buttons (2026-11-09, the user's ask): a light tap felt the
/// moment a row is pressed, and the row dims while held. Switches and the
/// Every Day / Customize choice keep their own selection tick instead.
struct SettingsTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.18), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { TapHaptic.play() }
            }
    }
}

/// The light tap Settings' buttons play.
enum TapHaptic {
    @MainActor static func play() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Pairing sheet — the parent is the one scanning, same as the real
// sign-up flow (ParentPairScanStep scans a code the CHILD's device shows;
// see ChildShowCodeStep's "Waiting for parent to scan…"). This screen
// stands in for that: it renders the code the child's device would be
// showing, inside the same dark camera-preview frame + scan line
// ParentPairScanStep uses — the parent points their camera at it and
// pairing completes on its own. No code to read aloud, nothing to type,
// nothing to configure: just the scan.
//
// This prototype has no live camera or second device, so "detecting" the
// code is a short timed stand-in for the real scan rather than an actual
// decode.

private struct PairingSheet: View {
    @ObservedObject var child: Child
    // True for Settings' "Add a child": `child` is only a stand-in, and the
    // backend creates the real profile when the code is claimed.
    var isNewChild = false
    // Fires once the child's device has been connected.
    var onPaired: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var redeemed = false
    @State private var connectedName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if redeemed {
                        redeemedView
                    } else {
                        VStack(spacing: 8) {
                            Text(isNewChild ? "Add your child's device" : "Pair \(child.name)'s device")
                                .font(Typography.font(20, weight: .heavy))
                                .foregroundStyle(EColor.onSurface)
                            Text("On the child's device, open Evlin and choose Child. It shows a QR code and a 6-digit code — scan it or type it here.")
                                .font(Typography.font(13, weight: .regular))
                                .foregroundStyle(EColor.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                        }
                        PairCodeEntry { code in
                            let claimed = try await APIClient.shared.claimPairing(
                                code: code, childId: isNewChild ? nil : child.id, newChild: isNewChild)
                            connectedName = claimed.name
                            await AppSync.shared.syncBackendData()
                            redeemed = true
                            onPaired?()
                        }
                    }
                }
                .padding(24)
            }
            .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
            .navigationTitle("Pair a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(redeemed ? "Done" : "Cancel") { TapHaptic.play(); dismiss() } }
            }
        }
    }

    private var redeemedView: some View {
        VStack(spacing: 14) {
            Circle().fill(EColor.secondary).frame(width: 64, height: 64)
                .overlay(Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white))
            Text("\(connectedName.isEmpty ? child.name : connectedName)'s device is paired")
                .font(Typography.font(18, weight: .bold))
                .foregroundStyle(EColor.onSurface)
            Text("Screen time is now enforced on this device.")
                .font(Typography.font(13, weight: .regular))
                .foregroundStyle(EColor.onSurfaceVariant)
        }
        .padding(.top, 20)
    }
}

/// Cream | Dark as a small switch, the picked part raised.
private struct AppearanceSwitch: View {
    @Binding var appearance: Appearance

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Appearance.allCases) { a in
                let on = appearance == a
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { appearance = a }
                } label: {
                    Text(a.name)
                        .font(Typography.font(13.5, weight: .semibold))
                        .foregroundStyle(on ? Neutral.ink : Neutral.secondary)
                        .frame(width: 54, height: 30)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(EColor.card)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Neutral.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sensoryFeedback(.selection, trigger: appearance)
    }
}
