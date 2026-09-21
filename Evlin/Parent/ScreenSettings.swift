import SwiftUI
import PhotosUI

// Structured to the "Settings — build spec" doc: account header (no card,
// opens a sheet) → Plan (removed entirely on Pro) → Family (capped list,
// each row opening the Child sheet) → Alerts → Support → a muted text
// footer. Every row is exactly one of chevron/toggle/read-only-value —
// never mixed — and every edit happens live inside the sheet a row opens,
// with a "Done" dismiss rather than Save/Cancel. Destructive actions never
// use an inline alert; they open DestructiveConfirmSheet instead.
struct ScreenSettings: View {
    var onSwitchMode: () -> Void
    var onSignOut: (() -> Void)? = nil

    // Root notification toggle — the only notification setting there is.
    @State private var pushOn = true

    // Parent identity — shown in the account header and edited in the
    // account sheet (parentProfilePage).
    private var profile: ParentProfile { ParentProfile.shared }
    private var parentName: String { profile.displayName }
    @State private var parentAvatar: UIImage?
    @State private var showChangeParentPicture = false
    @State private var parentLibraryItem: PhotosPickerItem?

    // Family list — capped at 5 rows with a "Show all N" / "Show fewer"
    // toggle, and the child a tap should open the Child sheet for.
    @State private var showAllChildren = false
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

    // Account/plan/legal sheets — chevron rows on the root list, each
    // opening a sheet rather than pushing.
    @State private var showParentProfile = false
    @State private var showBilling = false
    @State private var showPrivacyTerms = false

    // Destructive confirmations — always a sheet, never an inline alert.
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var showCancelPlanConfirm = false

    // Billing has no real StoreKit behind it yet (upgrade just flipped a
    // local flag after a fake delay, "Restore Purchases" did nothing) —
    // paused per product decision until real purchase + server-side
    // receipt validation exist. billingEnabled gates every entry point
    // below off until then; BillingState/billingPage stay in place as
    // scaffolding for that real build rather than being torn out.
    private let billingEnabled = false
    // Shared (BillingState.shared, not local @State) so the account
    // header's "Free plan"/"Pro" subtitle reflects whatever's set here.
    @ObservedObject private var billing = BillingState.shared
    @State private var isProcessingUpgrade = false

    var body: some View {
        NavigationStack {
            ScrollView {
                settingsRootContent
            }
            .background(Color.white)
            // Custom header (see settingsHeader) replaces the system nav
            // bar on this root screen — every destination below now opens
            // as its own sheet instead of pushing, so this stack never
            // actually navigates anywhere itself.
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $settingsChild) { child in
            ChildSettingsSheet(child: child, onRemoved: { familyRefreshTick += 1 })
        }
        // Straight into pairing the moment "Add a child" is tapped — see
        // addChildCard's action. The child this holds is only ever in
        // memory, not FamilyStore, until pairing actually succeeds (see
        // onPaired below) — so a child that's never paired never shows up
        // in the Family list or on Home. Closing this is the end of the
        // flow either way; naming/colouring happens later from the child's
        // own row, whenever the parent gets to it.
        .sheet(item: $newlyAddedChild) { child in
            PairingSheet(child: child, isNewChild: true, onPaired: {
                // The backend created the real child when it issued the
                // code; the sync inside PairingSheet has already loaded it.
                familyRefreshTick += 1
            })
        }
        .sheet(isPresented: $showParentProfile) {
            // The name field edits live; persist it when the sheet closes.
            parentProfilePage.onDisappear { profile.saveIfChanged() }
        }
        .sheet(isPresented: $showBilling) { NavigationStack { billingPage } }
        .sheet(isPresented: $showPrivacyTerms) { NavigationStack { privacyTermsPage } }
        .sheet(isPresented: $showCancelPlanConfirm) {
            DestructiveConfirmSheet(
                title: "Cancel Evlin Plus?",
                consequences: [
                    "You'll lose unlimited rules, AI strategies, and insights.",
                    "Pro access continues until the end of the current billing period.",
                ],
                destructiveLabel: "Cancel Subscription",
                onConfirm: {
                    billing.isPlus = false
                    showCancelPlanConfirm = false
                },
                onCancel: { showCancelPlanConfirm = false }
            )
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Root
    //
    // Hand-built instead of Form/Section: single-line rows by default (no
    // subtitle unless the row would otherwise be ambiguous — none here
    // are), small uppercase labels sitting tight against the group they
    // name, rows on a plain white page separated by hairline dividers —
    // Instagram-style, not Form's own insetGrouped card styling.

    // Custom title row (system nav bar is hidden on this screen — see
    // body) rather than .navigationTitle, so the title can sit at an exact
    // 28pt/bold the system large-title mechanism doesn't give direct
    // control over. No trailing button — it had nothing to open.
    private var settingsHeader: some View {
        Text("Settings")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Color.black)
            .padding(.bottom, 6)
    }

    private var visibleChildren: [Child] {
        showAllChildren ? FamilyStore.children : Array(FamilyStore.children.prefix(5))
    }

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
    @ViewBuilder
    private var settingsRootContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsHeader

            // Account + Plan are one subject (who you are, what you're
            // paying) — one card, not two.
            settingsAccountCard

            VStack(alignment: .leading, spacing: 12) {
                SectionHead("Family")
                VStack(spacing: 8) {
                    ForEach(visibleChildren) { child in
                        settingsFamilyChildCard(child)
                    }

                    if FamilyStore.children.count > 5 {
                        showAllChildrenRow(total: FamilyStore.children.count)
                    }

                    Button {
                        // Not added to FamilyStore here — only held in
                        // memory until pairing succeeds (see the
                        // newlyAddedChild sheet's onPaired), so a child
                        // that's never paired never appears on Home or in
                        // this list.
                        newlyAddedChild = Child(
                            id: UUID().uuidString, name: "New Child", age: 8, dailyLimitMin: 60,
                            color: FamilyStore.nextChildColor(), manualLock: false, taskGateOverride: false, timeLeft: formatMinutes(60), timePct: 100,
                            usageTodayMin: 0, subtitle: "No tasks yet"
                        )
                    } label: { addChildCard }
                        .buttonStyle(.plain)
                }
                // familyRefreshTick was being bumped on add/remove (see its
                // declaration above) but never actually read anywhere, so
                // SwiftUI had no reason to think this section's body-derived
                // content (visibleChildren, the FamilyStore.children.count
                // check above) had changed — bumping it was a complete
                // no-op. This list only ever caught up whenever some
                // *unrelated* state change happened to re-render the screen
                // afterward (backgrounding, navigating away and back, …),
                // which is what read as "it took too long." Keying this
                // subtree on the tick forces SwiftUI to discard and rebuild
                // it — and re-read FamilyStore.children fresh — the instant
                // a child is actually added or removed.
                .id(familyRefreshTick)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHead("Alerts")
                Card(padded: false) {
                    VStack(spacing: 0) {
                        settingsCompactRow(icon: "bell", title: "Push notifications", showChevron: false) {
                            Toggle("", isOn: $pushOn).labelsHidden().tint(EColor.secondary)
                        }

                        // "Billing and receipts" used to sit here — removed
                        // along with every other entry point into billing
                        // (see billingEnabled) since there's nothing real to
                        // show receipts for yet.
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHead("Support")
                Card(padded: false) {
                    VStack(spacing: 0) {
                        ShareLink(item: "I've been using Evlin to manage screen time for my kids — thought you might like it too.") {
                            settingsCompactRow(icon: "square.and.arrow.up", title: "Share Evlin")
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        // Honest about what this actually is — a mailbox,
                        // not a help center — and the prefilled metadata
                        // is what turns "it's not working" into something
                        // traceable.
                        Button {
                            if let url = reportProblemURL { UIApplication.shared.open(url) }
                        } label: {
                            settingsCompactRow(icon: "exclamationmark.bubble", title: "Report a problem")
                        }
                        .buttonStyle(.plain)
                        // "Replay the tours" used to sit here — removed;
                        // there's no tour/coach-mark system anywhere in the
                        // app for it to replay, so it never did anything.
                    }
                }
            }

            settingsFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // One card, one subject: who you are and what you're paying. On Pro
    // it's a single row (nothing left to upsell); on Free, a hairline
    // separates identity from the plan row — same facet-card pattern as
    // Alerts/Support, not two cards for one subject.
    private var settingsAccountCard: some View {
        let personColor = CalendarData.person("family").color
        return Card(padded: false) {
            VStack(spacing: 0) {
                Button { showParentProfile = true } label: {
                    HStack(spacing: 16) {
                        storyRingAvatar(color: personColor, initial: String(parentName.prefix(1)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(parentName).font(Typography.font(19, weight: .bold)).foregroundStyle(Color.black)
                            Text(billing.isPlus ? "Pro" : "Free plan")
                                .font(Typography.font(13, weight: .regular))
                                .foregroundStyle(Color(.secondaryLabel))
                        }
                        Spacer(minLength: 10)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Removed entirely once on Pro — a paying customer should
                // never see an upsell. Also gated on billingEnabled, since
                // there's no real purchase behind this yet (see its decl).
                if billingEnabled && !billing.isPlus {
                    settingsDivider
                    upgradeToProRow
                }
            }
        }
    }

    // Same content wherever it appears (this card and the Profile sheet)
    // — one subject's plan status shouldn't read differently depending on
    // which screen asked. Vanishes entirely once on Pro at every call
    // site, since that check lives with the caller, not in here.
    private var upgradeToProRow: some View {
        Button { showBilling = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Upgrade to Pro").font(Typography.font(15, weight: .bold)).foregroundStyle(Color.black)
                    Text("Repeating tasks, downtime, and bedtime are locked on the free plan.")
                        .font(Typography.font(12.5, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // The Instagram story-highlight look: a gradient ring, a thin white
    // gap, then the 62px avatar itself — not the gradient stroked directly
    // onto the avatar's own edge, which reads as a flat colored border
    // instead of a separate ring floating around it.
    private func storyRingAvatar(color: Color, initial: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [Color(hex: "FEDA75"), Color(hex: "FA7E1E"), Color(hex: "D62976"), Color(hex: "962FBF"), Color(hex: "4F5BD5"), Color(hex: "FEDA75")],
                        center: .center
                    )
                )
                .frame(width: 72, height: 72)
            Circle().fill(Color.white).frame(width: 68, height: 68)
            Circle().fill(color).frame(width: 62, height: 62)
                .overlay(Text(initial).font(Typography.font(23, weight: .bold)).foregroundStyle(.white))
        }
    }

    // Family is a list of entities, not facets of one subject — every
    // child is their own card, entirely tappable (no internal hairline;
    // there's nothing else in this card to separate). Opens the Child
    // sheet, where all of that child's editing (picture/name/colour/
    // screen time/device) actually happens.
    private func settingsFamilyChildCard(_ child: Child) -> some View {
        Button { settingsChild = child } label: {
            Card(padded: false) {
                HStack(spacing: 12) {
                    if let avatar = child.avatar {
                        Image(uiImage: avatar).resizable().scaledToFill()
                            .frame(width: 40, height: 40).clipShape(Circle())
                    } else {
                        Circle().fill(child.color).frame(width: 40, height: 40)
                            .overlay(Text(String(child.name.prefix(1))).font(Typography.font(15, weight: .bold)).foregroundStyle(.white))
                    }
                    Text(child.name).font(Typography.font(16, weight: .semibold)).foregroundStyle(Color.black)
                    Spacer(minLength: 10)
                    Text(child.devices.isEmpty ? "not paired" : "\(child.devices.count) \(child.devices.count == 1 ? "device" : "devices")")
                        .font(Typography.font(13, weight: .regular))
                        .foregroundStyle(child.devices.isEmpty ? EColor.danger : Color(.secondaryLabel))
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(.horizontal, 16)
                .frame(height: 64)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // A utility control, not an entity or a subject — it doesn't get a
    // card. Plain and centered so it doesn't compete with the cards
    // around it.
    private func showAllChildrenRow(total: Int) -> some View {
        Button { showAllChildren.toggle() } label: {
            Text(showAllChildren ? "Show fewer" : "Show all \(total)")
                .font(Typography.font(15, weight: .semibold))
                .foregroundStyle(EColor.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // A dashed plus circle in accent colour — part of the same list of
    // entities as the child cards above it (same card shell, same 8pt
    // gap), visually distinct only by the dashed ring so it never reads
    // as just another child.
    private var addChildCard: some View {
        Card(padded: false) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(EColor.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(EColor.secondary))
                Text("Add a child").font(Typography.font(16, weight: .bold)).foregroundStyle(EColor.secondary)
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
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

    // Small muted centered text, not rows — these are once-ever taps
    // (legal/version info), so they shouldn't compete with things people
    // actually use week to week.
    private var settingsFooter: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { showPrivacyTerms = true } label: {
                    Text("Privacy and terms")
                }
                .buttonStyle(.plain)
                Text("·")
                Text("Version \(appVersionString)")
            }
            .font(Typography.font(12, weight: .regular))
            .foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    // Edge-to-edge (spans the same width as the rows above it, not
    // indented on the trailing side) with only a leading inset, so it
    // starts under the row's text rather than under its icon/avatar.
    private var settingsDivider: some View {
        Rectangle()
            .fill(Color(.systemGray6))
            .frame(height: 1)
            .padding(.leading, 46)
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
            // Regular weight, plain black — clean line-art rather than a
            // colored badge behind a heavier glyph.
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.black)
                .frame(width: 22)
            Text(title).font(Typography.font(15.5, weight: .regular)).foregroundStyle(Color.black)
            Spacer(minLength: 10)
            if let value {
                Text(value).font(Typography.font(15, weight: .regular)).foregroundStyle(Color(.secondaryLabel))
            }
            trailing()
            if showChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        // Without this, only the icon/text/chevron glyphs themselves were
        // tappable — the Spacer-filled middle of the row (most of its
        // width) rendered nothing, so it didn't count as part of the
        // button's hit area at all. That's what made rows like "Share
        // Evlin" and "Billing and receipts" feel like they needed a
        // precise tap right on the text instead of anywhere on the row.
        .contentShape(Rectangle())
    }

    // MARK: - Billing (net-new — no StoreKit integration exists in this
    // prototype, so this is mocked plan/cycle state rather than a port)

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
                        showCancelPlanConfirm = true
                    } label: {
                        settingsRow(title: "Cancel Subscription", subtitle: "You'll keep Plus until the period ends", systemImage: "xmark.circle", accent: EColor.danger, danger: true)
                    }
                }
            }
        }
        .navigationTitle("Evlin Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { showBilling = false } }
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

    // MARK: - Parent Profile — a flat sheet, same chrome as Add Event/Add
    // to Calendar exactly: green "Cancel" top-left, bold title, labelled
    // pale fields, one primary action pinned at the bottom (here, Sign
    // Out — there's no Save because these fields edit live, same as the
    // Child sheet). No cards, no icons in rows, no placeholder rows for
    // things this prototype doesn't actually do.
    private var parentProfilePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Same top-bar placement as every other destructive delete in
            // this file (ChildSettingsSheet, EventDetailSheet) — a trash
            // icon beside Cancel, not a text link buried near the bottom.
            HStack {
                Button("Cancel") { showParentProfile = false }
                    .buttonStyle(.plain)
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())

                Spacer(minLength: 12)

                Button { showDeleteAccountConfirm = true } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(EColor.danger)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete account")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text("Profile")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 10) {
                        parentAvatarView
                        Button("Change picture") { showChangeParentPicture = true }
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(FormGreen.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 28)

                    FormField(label: "Your name") {
                        FormTextField(placeholder: "Your name", text: Binding(get: { profile.name }, set: { profile.name = $0 }))
                    }

                    // Same block as the root Settings list's account card
                    // — gone entirely once on Pro, same as there, and
                    // gated on billingEnabled for the same reason.
                    if billingEnabled && !billing.isPlus {
                        upgradeToProRow
                    }
                }
                .padding(.horizontal, 20)
            }
            .dismissKeyboardOnTap()
            .scrollDismissesKeyboard(.interactively)

            // Solid fill, not a soft tint — the same weight every other
            // destructive primary action in this file already uses
            // (DestructiveConfirmSheet's own button, ChildSettingsSheet's
            // Unpair), so this reads as the one real pinned action here,
            // not a muted secondary option.
            Button { showSignOutConfirm = true } label: {
                Text("Sign Out")
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(EColor.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: EColor.danger.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .background(Color.white)
        .photosPicker(isPresented: $showChangeParentPicture, selection: $parentLibraryItem, matching: .images)
        .onChange(of: parentLibraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { parentAvatar = downsampledAvatar(img) }
                }
            }
        }
        // Declared here, not on the Settings root — a second .sheet on the
        // presenting view doesn't stack on top of this already-presented
        // one, it replaces it, which read as "the Sign Out button and its
        // confirmation are two disconnected screens." Attaching it to this
        // sheet's own view instead is what makes it appear on top of
        // Profile, the same way ChildSettingsSheet's own confirm sheets do.
        .sheet(isPresented: $showSignOutConfirm) {
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
                    FamilyStore.clear() // Clear mock data just in case
                    onSignOut?() ?? onSwitchMode()
                },
                onCancel: { showSignOutConfirm = false }
            )
        }
        .sheet(isPresented: $showDeleteAccountConfirm) {
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
    }

    // Plain filled circle in the account's own colour (the same one the
    // Settings list's avatar uses, via CalendarData.person("family")) with
    // a single initial — no gradient ring, no separate "accent colour,"
    // matching how every other avatar in Settings (the Family list, the
    // Child sheet) is drawn.
    private var parentAvatarView: some View {
        Group {
            if let parentAvatar {
                Image(uiImage: parentAvatar).resizable().scaledToFill()
            } else {
                Circle().fill(CalendarData.person("family").color)
                    .overlay(Text(String(parentName.prefix(1))).font(Typography.font(38, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
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
        .navigationTitle("Privacy & Terms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { showPrivacyTerms = false } }
        }
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(EColor.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { onCancel() } label: {
                    Text(cancelLabel)
                        .font(Typography.font(16, weight: .semibold))
                        .foregroundStyle(EColor.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(EColor.surfaceContainerHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
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
private struct ChildSettingsSheet: View {
    @ObservedObject var child: Child
    var onRemoved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var libraryItem: PhotosPickerItem?
    @State private var showChangePicture = false
    @State private var showUnpairConfirm = false
    @State private var showRemoveConfirm = false
    @State private var showPairing = false
    @State private var nameOnOpen = ""
    // Screen time — moved here from the child's task-list profile (used to
    // be a generic "Active Rules" accordion, downtime shown as just another
    // row inside it). This is that child's actual settings/profile page,
    // so screen-time control belongs here, presented as what it is (a
    // limit and a schedule) rather than a generic rule list.
    @State private var editingRule: ChildRule?
    @State private var editingScreenTimeLimit = false
    // Turning off the daily limit removes a core protection entirely (not
    // just pausing a parent-authored rule), so it gets a confirm step the
    // other toggle below doesn't.
    @State private var showScreenTimeOffConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())

                Spacer(minLength: 12)

                Button { showRemoveConfirm = true } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(EColor.danger)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove child")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            VStack(spacing: 14) {
                childAvatar
                Text(child.name)
                    .font(Typography.font(28, weight: .heavy))
                    .foregroundStyle(FormGreen.title)
                Button("Change picture") { showChangePicture = true }
                    .font(Typography.font(14, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            .padding(.bottom, 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    FormField(label: "Name") {
                        FormTextField(placeholder: "Child's name", text: $child.name)
                    }

                    FormField(label: "Device") {
                        deviceRow
                    }

                    FormField(label: "Screen Time") {
                        screenTimeSection
                    }

                    if !customRules.isEmpty {
                        FormField(label: "Custom Rules") {
                            customRulesSection
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .dismissKeyboardOnTap()
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.white)
        .overlay {
            if showScreenTimeOffConfirm {
                ScreenTimeOffConfirmCard(
                    childName: child.name,
                    onTurnOff: {
                        if let i = child.rules.firstIndex(where: { $0.kind == .screenTimeLimit }) {
                            child.rules[i].on = false
                            child.pushRules()
                        }
                        withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = false }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = false } }
                )
            }
        }
        .sheet(item: $editingRule) { rule in
            EditRuleSheet(rule: rule, onSave: { updated in
                if let i = child.rules.firstIndex(where: { $0.id == updated.id }) { child.rules[i] = updated }
                child.pushRules()
                editingRule = nil
            }, onCancel: { editingRule = nil }, onDelete: {
                child.rules.removeAll { $0.id == rule.id }
                editingRule = nil
                if rule.kind == .downtime { exitDowntimeIfActive() }
                child.pushRules()
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
                    child.pushRules()
                    editingScreenTimeLimit = false
                },
                onCancel: { editingScreenTimeLimit = false }
            )
            .interactiveDismissDisabled()
        }
        .photosPicker(isPresented: $showChangePicture, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { child.avatar = downsampledAvatar(img) }
                }
            }
        }
        .sheet(isPresented: $showUnpairConfirm) {
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
                    showUnpairConfirm = false
                },
                onCancel: { showUnpairConfirm = false }
            )
        }
        .onAppear { nameOnOpen = child.name }
        .onDisappear {
            // The field edits the local Child live; persist it once the sheet
            // closes, otherwise the next backend sync would put the old name
            // back. (A removed child no longer exists locally: skip.)
            let newName = child.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard newName != nameOnOpen, !newName.isEmpty,
                  FamilyStore.children.contains(where: { $0.id == child.id }) else { return }
            let id = child.id
            BackendWrite.run("The new name") { try await APIClient.shared.updateChild(childId: id, name: newName) }
        }
        .sheet(isPresented: $showRemoveConfirm) {
            DestructiveConfirmSheet(
                title: "Remove \(child.name)'s profile?",
                consequences: [
                    "Tasks, history, and settings are deleted.",
                    "The device is unpaired and apps unlock.",
                    "This can't be undone.",
                ],
                destructiveLabel: "Remove Child",
                onConfirm: {
                    let removedId = child.id
                    FamilyStore.removeChild(removedId)
                    // If the backend delete fails the next sync brings the
                    // child back, which is the honest outcome.
                    BackendWrite.run("Removing the profile") { try await APIClient.shared.deleteChild(childId: removedId) }
                    showRemoveConfirm = false
                    dismiss()
                    onRemoved()
                },
                onCancel: { showRemoveConfirm = false }
            )
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(child: child)
        }
    }

    private var childAvatar: some View {
        Group {
            if let avatar = child.avatar {
                Image(uiImage: avatar).resizable().scaledToFill()
            } else {
                Circle().fill(child.color)
                    .overlay(Text(String(child.name.prefix(1))).font(Typography.font(38, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(EColor.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)
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

    // MARK: - Screen time

    private var dailyLimitRule: ChildRule? { child.rules.first { $0.kind == .screenTimeLimit } }
    private var downtimeRule: ChildRule? { child.rules.first { $0.kind == .downtime } }
    private var customRules: [ChildRule] { child.rules.filter { $0.kind == .custom } }

    // Two explicit, purpose-built rows — not a generic list iterating
    // child.rules the way this used to (which is also what buried Downtime
    // as just another row inside a collapsed "Active Rules" accordion).
    private var screenTimeSection: some View {
        VStack(spacing: 0) {
            if let rule = dailyLimitRule { screenTimeRow(rule, isBuiltIn: true) }
            if let rule = downtimeRule {
                Divider().padding(.leading, 16)
                screenTimeRow(rule, isBuiltIn: false)
            }
        }
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var customRulesSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(customRules.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Divider().padding(.leading, 16) }
                ruleRow(rule)
            }
        }
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func screenTimeRow(_ rule: ChildRule, isBuiltIn: Bool) -> some View {
        ruleRow(rule, onTap: { if isBuiltIn { editingScreenTimeLimit = true } else { editingRule = rule } })
    }

    private func ruleRow(_ rule: ChildRule, onTap: (() -> Void)? = nil) -> some View {
        let tap = onTap ?? { editingRule = rule }
        return HStack(spacing: 12) {
            Button(action: tap) {
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
            .buttonStyle(.plain)
            Spacer(minLength: 12)
            EToggle(on: Binding(
                get: { rule.on },
                set: { newValue in
                    guard let i = child.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                    // Screen Time Limit is the one built-in protection here —
                    // switching it off removes the daily cap entirely, not
                    // just pausing a rule, so it needs a beat to confirm
                    // rather than flipping instantly like the others.
                    if rule.kind == .screenTimeLimit && !newValue {
                        withAnimation(.easeOut(duration: 0.2)) { showScreenTimeOffConfirm = true }
                        return
                    }
                    child.rules[i].on = newValue
                    if rule.kind == .downtime && !newValue { exitDowntimeIfActive() }
                    child.pushRules()
                }
            ))
            Button(action: tap) {
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

    // Downtime is a schedule lock — turning the rule off (or deleting it)
    // while it's actively in effect needs to actually end the lock right
    // now, not just stop applying the *next* time downtime would start.
    private func exitDowntimeIfActive() {
        guard child.status == .downtime else { return }
        child.manualLock = false
        child.taskGateOverride = true
        child.timeLeft = formatMinutes(child.dailyLimitMin)
        child.timePct = 100
        child.downtimeUntil = nil
        let id = child.id
        BackendWrite.run("Unlocking the phone") {
            _ = try await APIClient.shared.updateChildState(childId: id, manualLock: false, taskGateOverride: true)
        }
    }
}

// MARK: - Screen Time edit sheets (moved here from ScreenProfile.swift —
// this child's settings/profile sheet is now where screen time is actually
// controlled, not the task-list profile)

// Screen Time Limit is the one built-in protection here — flipping it off
// removes the daily cap entirely (unlimited access until turned back on),
// unlike pausing a custom rule, so it gets its own confirm step instead of
// toggling instantly.
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
    static func blurb(_ kind: RuleKind) -> String {
        switch kind {
        case .downtime: return "A daily break from the screen — only phone calls and apps you allow will work."
        case .custom: return ""
        case .screenTimeLimit: return "The daily screen time allowance — a core protection you can pause but not edit or remove here."
        }
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
                // Unreachable in practice — the Screen Time row always opens
                // EditDailyScreenTimeLimitSheet instead — kept only so the
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

// The daily allowance backing the built-in Screen Time Limit rule — a quick-
// pick row of common limits plus a stepper for fine-tuning, mirroring the
// preset-chip pattern GrantExtraTimeSheet uses for "how much extra time."
// A native scrolling wheel picker for the actual minutes rather than
// tapping a stepper 15 minutes at a time; nothing saves until "Save
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
    // instead, so the warning keeps pace with the flick.
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
            .navigationTitle("Pair a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(redeemed ? "Done" : "Cancel") { dismiss() } }
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
