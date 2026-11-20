import SwiftUI

// The plan, the way current apps show it (Spotify, ChatGPT, Notion): a
// small badge by the parent's name, a soft card with a small Upgrade pill
// for the free plan, and one calm page when the parent chooses to look at
// it. No pop-ups and no big buttons pushed at anyone.
//
// There's no App Store purchase behind it yet (StoreKit isn't wired up):
// `EvlinPlan.offered` keeps every upgrade offer off for real families, and
// the demo shows them.

enum EvlinPlan {
    /// Upgrade offers are shown. Off until StoreKit is built: a real family
    /// must never be offered a purchase that isn't one.
    static var offered: Bool { DemoMode.isOn }

    /// The free plan covers one child; Pro, the whole family (2026-11-16,
    /// the user's call: the plan page shows when a second child is added,
    /// as Qustodio and OurPact do, the free tier one child). A family that
    /// already has more children keeps them all: nothing is taken away.
    static let freeChildren = 1

    /// Adding another child needs Pro: offers on, not on Pro, and the
    /// free plan's children already there.
    @MainActor static func needsPro(toAddTo childCount: Int) -> Bool {
        offered && !BillingState.shared.isPlus && childCount >= freeChildren
    }

    /// Picking this child needs Pro: only the Demo's example (Leo, the
    /// second child), to show the plan page as a free family meets it.
    @MainActor static func needsPro(toOpen childId: String) -> Bool {
        offered && !BillingState.shared.isPlus && childId == DemoMode.proExampleChildId
    }

    /// Days left of the family's free trial, shown on this child: only the
    /// Demo's Noah (3), to show the heads-up before it moves to the free
    /// plan (2026-11-17, the user's call).
    @MainActor static func trialDaysLeft(on childId: String) -> Int? {
        offered && !BillingState.shared.isPlus && childId == DemoMode.trialEndingChildId ? 3 : nil
    }

    /// Picking this child shows a plan card first: Leo's trial ended, or
    /// Noah's few days left.
    @MainActor static func cardOnOpen(_ childId: String) -> Bool {
        needsPro(toOpen: childId) || trialDaysLeft(on: childId) != nil
    }

    /// What Pro unlocks, and only that: things the free plan really locks.
    static let features: [(icon: String, tint: Color, title: String, detail: String)] = [
        ("figure.2.and.child.holdinghands", Color(hex: "30B0C7"), "Every child", "Add each of your children, all on one plan"),
        ("repeat", Color(hex: "0A84FF"), "Repeating tasks", "Daily or on set weekdays, without adding them again"),
        ("moon.fill", Color(hex: "5E5CE6"), "Downtime", "A daily break from the screen, on your schedule"),
        ("bed.double.fill", Color(hex: "FF9500"), "Bedtime", "Apps lock at night until the morning"),
    ]

    /// The app's one button green (`FormGreen.accent`, #2FA84F, #3A9257 at
    /// night), so the plan page's Continue, the picked price and the Pro
    /// badge match every other button (2026-11-17, the user's catch: the
    /// old bright #3FCE64 was left here when the greens became one).
    static let accent = FormGreen.accent
    static let gradient = LinearGradient(colors: [Color(light: "5CC27A", dark: "4CAF6A"), FormGreen.accent],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// "Free" in grey, or "Pro" with Evlin's flame-leaf in the Pro colours.
struct PlanBadge: View {
    var isPlus: Bool

    var body: some View {
        HStack(spacing: 3) {
            if isPlus { FlameLeaf().fill(Color.white).frame(width: 7, height: 9) }
            Text(isPlus ? "Pro" : "Free").font(Typography.font(11, weight: .bold))
        }
        .foregroundStyle(isPlus ? .white : EColor.onSurfaceVariant)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            if isPlus { Capsule().fill(EvlinPlan.gradient) } else { Capsule().fill(EColor.surfaceContainerHigh) }
        }
    }
}

/// The free plan's offer: a soft card, a line about what Pro adds, and a
/// small pill. The whole card opens the plan page.
struct UpgradeCard: View {
    var title = "Try Evlin Pro"
    var subtitle = "Gain access to all advanced features"
    var onUpgrade: () -> Void
    /// Shown as a small x when the card can be put away (Home's).
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        Button(action: onUpgrade) {
            HStack(spacing: 12) {
                PlusMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                    Text(subtitle).font(Typography.font(12.5, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text("Upgrade")
                    .font(Typography.font(13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(EvlinPlan.accent, in: Capsule())
            }
            .padding(14)
            .background(EvlinPlan.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(EvlinPlan.accent.opacity(0.28), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(width: 20, height: 20)
                        .background(EColor.surfaceContainerHigh, in: Circle())
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 10, y: -10)
                .accessibilityLabel("Not now")
            }
        }
    }
}

/// The plan page: what Pro unlocks and the two ways to pay, or, on Pro,
/// what you have and how to manage it.
struct EvlinPlanSheet: View {
    /// Why it opened, when a parent reached for something Pro covers: the
    /// page says so first (a paywall at the moment of intent, not one to
    /// hunt for).
    enum Reason: Equatable { case anotherChild, child(String), trialEnds(days: Int) }
    var reason: Reason? = nil
    /// After a purchase made for `reason`: carries on with what the parent
    /// was doing (adding the child), the page closing itself.
    var onUnlocked: (() -> Void)? = nil

    @ObservedObject private var billing = BillingState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var upgrading = false
    @State private var showCancelConfirm = false

    private var headline: String {
        switch reason {
        case .anotherChild: "Add your next child"
        case .child(let name): "Add \(name) to your plan"
        case .trialEnds(let days): "Your free trial ends in \(days) days"
        case nil: "Get more from Evlin"
        }
    }

    private var subtitle: String {
        switch reason {
        case .anotherChild, .child: "The free plan covers one child. With Pro you get:"
        case .trialEnds: "Then you move to the free plan, which covers one child. Keep it all with Pro:"
        case nil: "Everything on the free plan, plus:"
        }
    }

    private var price: String { billing.billingCycle == .yearly ? "$79.99 a year" : "$9.99 a month" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        PlanBadge(isPlus: true)
                        Text(billing.isPlus ? "You're on Evlin Pro" : headline)
                            .font(Typography.font(28, weight: .heavy))
                            .foregroundStyle(FormGreen.title)
                        Text(billing.isPlus ? "Thanks for supporting Evlin." : subtitle)
                            .font(Typography.font(15, weight: .regular))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }

                    VStack(spacing: 14) {
                        ForEach(EvlinPlan.features, id: \.title) { feature in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(feature.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title).font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                                    Text(feature.detail).font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if billing.isPlus {
                        manageRows
                    } else {
                        VStack(spacing: 10) {
                            cycleOption(.yearly, title: "Yearly", price: "$79.99 a year", note: "Save 33%")
                            cycleOption(.monthly, title: "Monthly", price: "$9.99 a month", note: nil)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            if !billing.isPlus {
                VStack(spacing: 8) {
                    Button {
                        upgrading = true
                        // No StoreKit yet: stands in for the purchase.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            upgrading = false
                            withAnimation { billing.isPlus = true }
                            if let onUnlocked {
                                dismiss()
                                onUnlocked()
                            }
                        }
                    } label: {
                        Group {
                            if upgrading { ProgressView().tint(.white) } else { Text("Continue · \(price)") }
                        }
                        .font(Typography.font(16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(EvlinPlan.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(upgrading)
                    HStack(spacing: 20) {
                        // A way out that's plain to see (the paywall is never
                        // a dead end): only when it opened for a reason.
                        if reason != nil {
                            Button("Not now") { dismiss() }
                        }
                        Button("Restore purchases") {}
                    }
                    .font(Typography.font(12.5, weight: .semibold))
                    .foregroundStyle(EColor.onSurfaceVariant)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .background(EColor.surface)
        .alert("Cancel Evlin Pro?", isPresented: $showCancelConfirm) {
            Button("Cancel Pro", role: .destructive) { withAnimation { billing.isPlus = false } }
            Button("Keep Pro", role: .cancel) {}
        } message: {
            Text("You'll keep Pro until the end of this billing period.")
        }
    }

    private var manageRows: some View {
        VStack(spacing: 0) {
            Button {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") { UIApplication.shared.open(url) }
            } label: {
                planRow("Manage subscription", detail: billing.billingCycle == .yearly ? "Yearly" : "Monthly", tint: EColor.onSurface)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 16)
            Button { showCancelConfirm = true } label: {
                planRow("Cancel subscription", detail: nil, tint: EColor.danger)
            }
            .buttonStyle(.plain)
        }
        .background(FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func planRow(_ title: String, detail: String?, tint: Color) -> some View {
        HStack {
            Text(title).font(Typography.font(15, weight: .semibold)).foregroundStyle(tint)
            Spacer()
            if let detail { Text(detail).font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private func cycleOption(_ cycle: BillingCycle, title: String, price: String, note: String?) -> some View {
        let selected = billing.billingCycle == cycle
        return Button { billing.billingCycle = cycle } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? EvlinPlan.accent : EColor.outlineVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                    Text(price).font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                }
                Spacer()
                if let note {
                    Text(note)
                        .font(Typography.font(11, weight: .bold))
                        .foregroundStyle(EvlinPlan.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(EvlinPlan.accent.opacity(0.1), in: Capsule())
                }
            }
            .padding(14)
            .background(selected ? EvlinPlan.accent.opacity(0.06) : FormGreen.fieldBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? EvlinPlan.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// A child the free plan doesn't cover (the Demo's Leo): a small half card
/// first, saying the trial is over, and only on Upgrade the plan page
/// (2026-11-16, the user's call: the full page straight away was too much).
struct ChildTrialEndedCard: View {
    let child: Child
    /// Days left of the trial (Noah), or nil when it has ended (Leo).
    var daysLeft: Int? = nil
    let onUpgrade: () -> Void
    let onCancel: () -> Void

    private var title: String {
        guard let daysLeft else { return "\(child.name)’s free trial has ended" }
        return "\(daysLeft) days left of your free trial"
    }
    private var words: String {
        guard daysLeft != nil else { return "The free plan covers one child. Upgrade to Pro to keep \(child.name) on Evlin." }
        return "Then your account moves to the free plan, which covers one child. Upgrade to Pro to keep \(child.name) and every feature."
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(String(child.name.prefix(2)).uppercased())
                .font(Typography.font(19, weight: .heavy))
                .foregroundStyle(child.color)
                .frame(width: 64, height: 64)
                .background(child.color.opacity(0.16), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: daysLeft == nil ? "lock.fill" : "hourglass")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(daysLeft == nil ? EColor.onSurfaceVariant : HomeStyle.waiting)
                        .frame(width: 24, height: 24)
                        .background(EColor.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Neutral.line, lineWidth: 1))
                        .offset(x: 4, y: 4)
                }
                .padding(.bottom, 2)
            VStack(spacing: 6) {
                Text(title)
                    .font(Typography.font(21, weight: .bold))
                    .foregroundStyle(EColor.onSurface)
                Text(words)
                    .font(Typography.font(15.5, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Button(action: onUpgrade) {
                    Text("Upgrade to Pro")
                        .font(Typography.font(16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(CardPressStyle(haptic: true))
                Button(action: onCancel) {
                    Text("Not now")
                        .font(Typography.font(15.5, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(EColor.raised)
    }
}

extension View {
    /// The trial-ended card for `child`, then the plan page if the parent
    /// upgrades; `onUnlocked` runs once bought.
    func childTrialEnded(_ child: Binding<Child?>, demoOpens: Bool = false, onUnlocked: @escaping (Child) -> Void) -> some View {
        modifier(ChildTrialEndedFlow(child: child, demoOpens: demoOpens, onUnlocked: onUnlocked))
    }
}

private struct ChildTrialEndedFlow: ViewModifier {
    @Binding var child: Child?
    var demoOpens = false
    let onUnlocked: (Child) -> Void
    @State private var planFor: Child?
    @State private var upgradeTapped: Child?

    func body(content: Content) -> some View {
        content
            .sheet(item: $child, onDismiss: {
                // The plan page opens once the card is gone.
                if let c = upgradeTapped { upgradeTapped = nil; planFor = c }
            }) { c in
                ChildTrialEndedCard(child: c, daysLeft: EvlinPlan.trialDaysLeft(on: c.id),
                                    onUpgrade: { upgradeTapped = c; child = nil },
                                    onCancel: { child = nil })
                    .presentationDetents([.height(EvlinPlan.trialDaysLeft(on: c.id) == nil ? 370 : 395)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(EColor.raised)
            }
            // Demo: `noahplan` opens the plan page Noah's card leads to
            // (only from the view that sets `demoOpens`, Home).
            .task {
                guard demoOpens, DemoMode.parentOpen == "noahplan",
                      let noah = FamilyStore.children.first(where: { EvlinPlan.trialDaysLeft(on: $0.id) != nil }) else { return }
                try? await Task.sleep(for: .seconds(0.6))
                planFor = noah
            }
            .sheet(item: $planFor) { c in
                EvlinPlanSheet(reason: EvlinPlan.trialDaysLeft(on: c.id).map { .trialEnds(days: $0) } ?? .child(c.name)) { onUnlocked(c) }
                    .presentationDragIndicator(.visible)
            }
    }
}

/// The parent's initial in a soft circle: Profile's top right in place of
/// the gear (it opens Settings), and large at the top of Settings.
struct ParentAvatar: View {
    var size: CGFloat = 34

    var body: some View {
        let name = ParentProfile.shared.displayName
        Text(String((name.isEmpty ? "You" : name).prefix(1)).uppercased())
            .font(Typography.font(size * 0.42, weight: .bold))
            .foregroundStyle(Neutral.ink)
            .frame(width: size, height: size)
            .background(EColor.chip, in: Circle())
            .overlay(Circle().strokeBorder(EColor.chipEdge, lineWidth: 1))
    }
}

/// Profile's way into Settings: the parent's avatar and name, top left
/// (2026-11-17, the user's call; the avatar alone where the gear was, just
/// before, didn't say whose account it was). The name gives way first.
struct ParentNameButton: View {
    let action: () -> Void

    var body: some View {
        let name = ParentProfile.shared.displayName
        Button(action: action) {
            HStack(spacing: 7) {
                ParentAvatar(size: 34)
                Text(name.isEmpty ? "You" : name)
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(haptic: true))
        .accessibilityLabel("\(name.isEmpty ? "You" : name). Settings")
    }
}

/// The free plan's Upgrade on Profile: a green pill in a soft green glow
/// that breathes, so it reads as the one thing to press (2026-11-17, the
/// user's call). Still with Reduce Motion.
struct GlowingUpgradeButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var glow = false

    var body: some View {
        let dim = colorScheme == .dark ? 0.55 : 1.0
        Button(action: action) {
            Text("Upgrade")
            .font(Typography.font(14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(FormGreen.accent, in: Capsule())
            .shadow(color: FormGreen.accent.opacity((glow ? 0.6 : 0.25) * dim), radius: glow ? 10 : 4)
            .contentShape(Capsule())
        }
        .buttonStyle(CardPressStyle(haptic: true))
        .accessibilityLabel("Upgrade to Pro")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

/// The top of Settings in place of its title (2026-11-17, the user's
/// calls): one account row, the parent's avatar, name and plan ("Free
/// plan", the trial's days left in orange, or "Pro" in green) with a ›, a
/// tap anywhere on it opening the account (Edit account, Sign out); a long
/// name ends in "…". On the free plan a full-width Upgrade under it, its
/// word glowing. Off the Demo (no purchases yet) the avatar and name.
struct SettingsProfileHead: View {
    let onAccount: () -> Void
    let onUpgrade: () -> Void
    @ObservedObject private var billing = BillingState.shared

    var body: some View {
        let name = ParentProfile.shared.displayName
        let trial = EvlinPlan.trialDaysLeft(on: SessionManager.shared.activeChildId ?? "")
        let plan = billing.isPlus ? "Pro" : trial.map { "Free trial · \($0) days left" } ?? "Free plan"
        VStack(spacing: 14) {
            Button(action: onAccount) {
                HStack(spacing: 14) {
                    ParentAvatar(size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name.isEmpty ? "You" : name)
                            .font(Typography.font(23, weight: .bold))
                            .foregroundStyle(EColor.onSurface)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(EvlinPlan.offered ? plan : "Account")
                            .font(Typography.font(14.5, weight: billing.isPlus || trial != nil ? .semibold : .regular))
                            .foregroundStyle(billing.isPlus && EvlinPlan.offered ? FormGreen.accent
                                             : trial != nil ? HomeStyle.waiting : EColor.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StatusCardStyle.tertiaryLabel)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsTapStyle())
            .accessibilityLabel(EvlinPlan.offered ? "\(name), \(plan). Account" : "\(name). Account")
            if EvlinPlan.offered && !billing.isPlus {
                UpgradeWideButton(action: onUpgrade)
            }
        }
    }
}

/// Settings' Upgrade, full width under the account: the button green, its
/// word glowing (a soft light breathing round the letters and a shine
/// passing over them now and then). Still with Reduce Motion.
struct UpgradeWideButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false
    @State private var shine: CGFloat = -1

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                FlameLeaf().fill(Color.white).frame(width: 10, height: 13)
                Text("Upgrade to Pro")
            }
            .font(Typography.font(16.5, weight: .bold))
            .foregroundStyle(.white)
            // The word's glow: a white light round the letters.
            .shadow(color: .white.opacity(glow ? 0.9 : 0.3), radius: glow ? 7 : 2)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: shine * geo.size.width)
                }
                .mask(HStack(spacing: 7) {
                    FlameLeaf().frame(width: 10, height: 13)
                    Text("Upgrade to Pro").font(Typography.font(16.5, weight: .bold))
                })
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: FormGreen.accent.opacity(glow ? 0.45 : 0.15), radius: glow ? 12 : 5)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardPressStyle(haptic: true))
        .accessibilityLabel("Upgrade to Pro")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if Task.isCancelled { return }
                shine = -0.5
                withAnimation(.easeInOut(duration: 1.0)) { shine = 1.2 }
            }
        }
    }
}
