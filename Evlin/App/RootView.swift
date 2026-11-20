import SwiftUI
import UIKit
import Sentry

enum AppMode: String, CaseIterable, Identifiable {
    case parent, tablet
    var id: String { rawValue }
    var label: String { self == .parent ? "Parent" : "Child" }
}

struct RootView: View {
    @State private var session = SessionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var mode: AppMode?
    // Separate per role — a parent and a kid go through entirely different
    // onboarding chains (accounts/PIN/pairing vs. consent/permissions), so
    // finishing one must never skip the other. (A single shared flag used to
    // gate both; that made switching to Child mode after parent onboarding
    // skip OnboardingV2Coordinator(role: .child) entirely.) Remembered across
    // launches (UserDefaults) but only honoured while the matching login /
    // device token is still in the Keychain — see init.
    @State private var parentOnboarded: Bool
    @State private var childOnboarded: Bool
    @State private var signedOutNotice = false
    /// Why the last sign-out happened (APIClient's 401 handling).
    @State private var signedOutReason: String?
    // Brief brand splash before the mode picker, matching the reference
    // flow's full-bleed logo screen ahead of onboarding.
    @State private var showSplash = true
    // Filled by the parent's pairing poll (see ParentScanCodeStep).
    @State private var pairedKidName: String?
    /// Settings > Appearance: Cream or Dark.
    @AppStorage(Appearance.key) private var appearance: Appearance = .cream

    /// The parent's app (its opening screen included, so Dark opens dark,
    /// 2026-11-07) follows Appearance; everything else is Cream.
    private var lookScheme: ColorScheme? {
        if mode == .parent && parentOnboarded { return appearance.scheme }
        // The kid's side follows the iPad's own light or dark: cream
        // e-paper, or a warm night e-paper (`WarmNight`), never black
        // (2026-11-09, the user's call).
        if mode == .tablet { return nil }
        // Setting up (onboarding, the start screen): the device's own light
        // or dark, since most parents set up at night (2026-11-08).
        return nil
    }

    private static func applyLook(_ scheme: ColorScheme?) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : (scheme == .light ? .light : .unspecified)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }

    enum Saved {
        static let mode = "evlin.mode"
        static let parent = "evlin.parentOnboarded"
        static let child = "evlin.childOnboarded"
    }

    init() {
        #if EVLIN_DEMO
        if DemoMode.isOn {
            DemoMode.seedIfOn()
        }
        #endif
        let saved = Self.savedSession()
        _parentOnboarded = State(initialValue: saved.parent)
        _childOnboarded = State(initialValue: saved.child)
        let previewMode: AppMode? = DemoMode.kidOnboardingStep != nil ? .tablet
            : (DemoMode.parentOnboardingStep != nil ? .parent : (DemoMode.isOn ? (DemoMode.isKid ? .tablet : .parent) : saved.mode))
        _mode = State(initialValue: previewMode)
        Self.setWarmNight(previewMode)
    }

    /// The warm night (`WarmNight`) for the kid's side, and for an iPad that
    /// hasn't picked a side yet (most iPads are the kid's).
    private static func setWarmNight(_ m: AppMode?) {
        WarmNight.on = m == .tablet || (m == nil && UIDevice.current.userInterfaceIdiom == .pad)
    }

    /// Who was signed in last time, from the Keychain and UserDefaults, and
    /// the role to reopen straight into.
    static func savedSession() -> (parent: Bool, child: Bool, mode: AppMode?) {
        #if EVLIN_DEMO
        if DemoMode.isOn {
            // Set up already, unless a launch flag opens setup at a step.
            return DemoMode.isKid ? (false, DemoMode.kidOnboardingStep == nil, .tablet)
                                  : (DemoMode.parentOnboardingStep == nil, false, .parent)
        }
        #endif
        let d = UserDefaults.standard
        let s = SessionManager.shared
        let parentOK = s.hasParentSession && d.bool(forKey: Saved.parent)
        let childOK = s.hasChildSession && d.bool(forKey: Saved.child)
        let last = d.string(forKey: Saved.mode).flatMap(AppMode.init(rawValue:))
        // A kid's phone that was reinstalled: the Keychain kept its device
        // token but UserDefaults lost everything. Go straight back to the
        // kid side, where onboarding skips pairing (OnboardingV2Coordinator).
        if !s.hasParentSession, s.hasChildSession, !childOK, last == nil {
            return (parentOK, false, .tablet)
        }
        // Signed in but setup not finished (closed while pairing a kid, say):
        // back to the parent side, where onboarding skips the sign-in step.
        // A parent signs in once; only Sign out asks again.
        if s.hasParentSession, !parentOK, last != .tablet {
            return (false, childOK, .parent)
        }
        return (parentOK, childOK, (last == .parent && parentOK) || (last == .tablet && childOK) ? last : nil)
    }

    /// A launch before the phone's first unlock reads an empty Keychain and
    /// shows the mode picker. Once it opens, pick the session back up. Only
    /// while nobody is in: a sign-out cleared the Keychain, so it can't come
    /// back this way.
    private func restoreSessionIfMissed() {
        #if EVLIN_DEMO
        if DemoMode.isOn { return }
        #endif
        guard !parentOnboarded, !childOnboarded, mode == nil else { return }
        SessionManager.shared.reloadMissingFromKeychain()
        let saved = Self.savedSession()
        guard saved.parent || saved.child else { return }
        if saved.parent { LocalStore.shared.hydrateIfNeeded() }
        parentOnboarded = saved.parent
        childOnboarded = saved.child
        mode = saved.mode
        Task { await AppSync.shared.syncBackendData() }
    }

    /// The live-updates stream runs exactly while someone is signed in and
    /// the app is on screen. iOS suspends a backgrounded app's sockets
    /// anyway, and the foreground sync below catches up on return.
    private func updateLiveUpdates() {
        if scenePhase == .active && (parentOnboarded || childOnboarded) {
            LiveUpdates.shared.start()
        } else {
            LiveUpdates.shared.stop()
        }
    }

    /// The backend refused the stored login/device token for good: forget
    /// everything local and start over from the mode picker.
    private func signOutBecauseSessionEnded() {
        #if EVLIN_DEMO
        if DemoMode.isOn { return }
        #endif
        SessionManager.shared.clear()
        FamilyStore.clear()
        parentOnboarded = false
        childOnboarded = false
        mode = nil
        signedOutNotice = true
    }

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
            } else {
                switch mode {
                case .none:
                    ModePickerView(mode: $mode)
                case .parent:
                    if parentOnboarded {
                        ParentRootView(onSwitchMode: { mode = nil }, onSignOut: { parentOnboarded = false; mode = nil })
                            .environment(session)
                    } else {
                        OnboardingV2Coordinator(
                            role: .parent,
                            onExitToModePicker: { mode = nil },
                            onComplete: {
                                #if EVLIN_DEMO
                                if DemoMode.previewsOnboarding {
                                    // A new family: the child alone, no tasks.
                                    let name = DemoPairBridge.read()?.kidName ?? pairedKidName
                                    DemoMode.startNewFamily(kidName: (name?.isEmpty == false ? name : nil) ?? "Mia")
                                    parentOnboarded = true
                                    return
                                }
                                #endif
                                // Show the app as soon as sign-in/setup is done.
                                // First-run SwiftData creation and the full sync
                                // can take long enough to make this button feel
                                // dead; Home has its own first-sync loading state.
                                LocalStore.shared.hydrateIfNeeded()
                                parentOnboarded = true
                                Task {
                                    await AppSync.shared.syncBackendData()
                                    if FamilyStore.children.isEmpty {
                                        FamilyStore.addOnboardedChild(name: pairedKidName ?? "Your child")
                                        SyncState.shared.publish()
                                    }
                                }
                            }
                        )
                    }
                case .tablet:
                    if childOnboarded {
                        TabletRootView(onSwitchMode: { mode = nil })
                            .environment(session)
                    } else {
                        OnboardingV2Coordinator(
                            role: .child,
                            onExitToModePicker: { mode = nil },
                            onComplete: { 
                                #if EVLIN_DEMO
                                if DemoMode.previewsOnboarding {
                                    // The paired child alone: none of the sample family.
                                    let name = DemoPairBridge.read()?.kidName
                                    DemoMode.startNewFamily(kidName: (name?.isEmpty == false ? name : nil) ?? "Mia", asParent: false)
                                    childOnboarded = true
                                    return
                                }
                                #endif
                                childOnboarded = true 
                                Task { await AppSync.shared.syncBackendData() }
                            }
                        )
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
        // The one place the look is set: the parent's app follows Appearance;
        // everything else (the kid's side, onboarding, the start screens)
        // is always Cream.
        // On the window itself, so sheets already open (Settings, where it's
        // changed) switch too, and Auto goes back to following the phone.
        .onChange(of: lookScheme, initial: true) { _, scheme in Self.applyLook(scheme) }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("EvlinKidPaired"))) { note in
            if let name = note.object as? String, !name.isEmpty { pairedKidName = name }
        }
        .onChange(of: mode) { _, new in
            Self.setWarmNight(new)
            UserDefaults.standard.set(new?.rawValue, forKey: Saved.mode)
        }
        .onChange(of: parentOnboarded) { _, new in
            UserDefaults.standard.set(new, forKey: Saved.parent)
            updateLiveUpdates()
        }
        .onChange(of: childOnboarded) { _, new in
            UserDefaults.standard.set(new, forKey: Saved.child)
            updateLiveUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .evlinSessionExpired)) { note in
            guard parentOnboarded || childOnboarded else { return }
            let reason = note.object as? String ?? "unknown"
            signedOutReason = reason
            // Every sign-out reaches Sentry with its cause, TestFlight
            // builds included, so one that shouldn't happen can be traced.
            SentrySDK.capture(message: "Signed out: \(reason)")
            signOutBecauseSessionEnded()
        }
        .alert("You've been signed out", isPresented: $signedOutNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            #if DEBUG
            Text("Your session ended. Please sign in again.\n\n\(signedOutReason ?? "")")
            #else
            Text("Your session ended. Please sign in again.")
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            restoreSessionIfMissed()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restoreSessionIfMissed() }
            if phase == .active, parentOnboarded || childOnboarded {
                Task { await AppSync.shared.syncBackendData() }
            }
            // Leaving: send what's waiting with the seconds iOS allows, and
            // book the next background refresh.
            if phase == .background, parentOnboarded || childOnboarded {
                BackgroundSync.finishPendingWork()
                BackgroundSync.scheduleRefresh()
            }
            updateLiveUpdates()
        }
        // Used to be a blanket dismissKeyboardOnTap() here covering the
        // whole app (mode picker, every onboarding step, both tab roots) —
        // sat on top of screens with no text fields at all too, including
        // Settings' root list, where its simultaneousGesture measurably
        // delayed plain NavigationLink row taps (a short tap stopped
        // registering; only a longer press did). Removed in favor of
        // wiring it onto the specific screens/containers that actually
        // have fields (OnboardingV2ScreenContainer, FormShell, chat, etc.)
        // — see dismissKeyboardOnTap()'s own doc comment for why
        // simultaneousGesture alone doesn't fully prevent this at the
        // scale of "every screen in the app."
        .task {
            // The family's last known state first, from the phone, so the
            // app opens with real content instead of waiting on the network.
            // (The kid side does the same in TabletRootView.)
            if parentOnboarded { LocalStore.shared.hydrateIfNeeded() }
            DayClock.shared.start()
            Outbox.startWatchingNetwork()
            updateLiveUpdates()
            // Sync starts now, under the splash, not after it.
            let sync = Task {
                if parentOnboarded || childOnboarded { await AppSync.shared.syncBackendData() }
            }
            // The splash stays a beat for the brand, then until the first
            // sync has brought the latest tasks, capped so a slow network
            // never holds the app closed. It used to lift as soon as the
            // saved data was in, which showed the last session's state
            // (tasks since approved or sent in) for a second before the
            // sync replaced it. Past the cap, the saved data shows.
            try? await Task.sleep(nanoseconds: 450_000_000)
            let started = Date()
            while (parentOnboarded || childOnboarded)
                    && !SyncState.shared.hasFreshChildren
                    && !SyncState.shared.hasFinishedFirstSync
                    && !DemoMode.isOn
                    && Date().timeIntervalSince(started) < 2.5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            withAnimation(.easeInOut(duration: 0.2)) { showSplash = false }
            await sync.value
        }
    }
}

// Brand splash: our leaf centred on the page, with a thin pulsing green
// loading bar near the bottom.
/// The opening splash and the start screen's page: the app's off-white,
/// #FAF9F6, by day (2026-11-14, the user's call; a cool grey, #F3F4F6, and
/// Alabaster, #EDEAE0, earlier that day); the blue charcoal at night.
enum StartPage {
    static let background = Color(light: "FAF9F6", dark: "1C1F24", warm: "1C1F24")
    /// The Child button: the soft mint, a little brighter, with darker
    /// words to read easily (2026-11-14; Brand.mint #D0F1C9 / #21392A with
    /// #182C20 / #CDEFD6 words before).
    static let childFill = Color(light: "A4E3AA", dark: "2F563B", warm: "2F563B")
    static let childInk = Color(light: "0F3A1E", dark: "EAF7EC", warm: "EAF7EC")
    /// The Parent button: setup's soft mid green, #34B85A (#3A9257 at
    /// night), as the Family Sharing question's Yes (2026-11-16, the
    /// user's call; the mascot #3FCE64, `Brand.emerald`, before).
    static let parentFill = OnboardingV2Theme.Palette.button
    /// The Child button since 2026-11-16 (the user's layout): outlined, the
    /// page's own colour with a deep-green edge and deep-green words (the
    /// mint #A4E3AA with #0F3A1E words before; a cream fill with a green
    /// edge was tried and reverted on 2026-11-14, before this layout).
    static let childEdge = Color(light: "2E7D32", dark: "6FDC8C", warm: "6FDC8C")
    /// A faint soft glow behind the leaf.
    static let glow = Color(light: "000000", dark: "FFFFFF", warm: "FFFFFF")
}

/// A start screen button's face (2026-11-16, the user's layout): Parent
/// solid in setup's soft green with white words, Child outlined in deep
/// green; both semibold, narrower than the page, a little rounded.
private struct StartModeLabel: View {
    var mode: AppMode
    var isRegular: Bool

    var body: some View {
        let parent = mode == .parent
        // Setup's button shape, so Parent feels the same as Continue with
        // Email (2026-11-16, the user's call; 52pt tall with corners 20, and
        // 14 before that, the same day).
        let m = OnboardingV2Theme.Metrics.self
        let shape = RoundedRectangle(cornerRadius: isRegular ? m.ctaCornerRadius + 10 : m.ctaCornerRadius, style: .continuous)
        return Text(mode.label)
            .font(Typography.font(isRegular ? 26 : 17, weight: .semibold))
            .foregroundStyle(parent ? Color.white : StartPage.childEdge)
            .frame(maxWidth: .infinity)
            .frame(height: isRegular ? m.ctaHeightRegular : m.ctaHeightCompact)
            .background(parent ? StartPage.parentFill : StartPage.background, in: shape)
            .overlay(shape.strokeBorder(parent ? Color.clear : StartPage.childEdge, lineWidth: 1.5))
            .contentShape(shape)
    }
}

struct SplashScreenView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Rectangle().fill(StartPage.background).ignoresSafeArea()

            // Our leaf on its own, as on the start screen (2026-11-12, the
            // user's call; the app icon's green tile before).
            Image("LeafMark")
                .resizable()
                .scaledToFit()
                .frame(height: 104)

            VStack {
                Spacer()
                Capsule()
                    .fill(Brand.greenDeep.opacity(pulse ? 1 : 0.25))
                    .frame(width: 120, height: 4)
                    .padding(.bottom, 48)
            }
        }
        .task {
            // A `repeatForever` animation kicked off directly in .onAppear
            // races with SwiftUI's own transaction for the view's initial
            // appearance — most of the time it wins and the pulse starts
            // fine, but sometimes it loses that race and the animation
            // never actually begins, leaving the bar stuck at its static
            // starting opacity. A one-tick defer (this .task always runs
            // in its own transaction, after appear) sidesteps the race
            // instead of just narrowing the window.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// Mirrors the web build's separate Evlin_Parent_view / Evlin_Tablet_view apps:
// one native binary, choose which experience to enter.
struct ModePickerView: View {
    @Binding var mode: AppMode?
    // Same fix as OnboardingV2ScreenContainer (see its own comment): this
    // screen comes before onboarding even starts, in this file rather than
    // Onboarding/, so it didn't pick up that container's cap and was still
    // stretching its Parent/Child buttons edge to edge on iPad. Reuses that
    // same centered-column constant rather than a second magic number.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        // One group centred on the page (2026-11-16, the user's layout):
        // the leaf on a faint soft glow, the name and the line under it,
        // then Parent and Child right under them, narrower than the page.
        // The buttons sat at the foot of the page, full width, before.
        VStack(spacing: 0) {
            Spacer()
            // Our leaf on its own, `evlin-leaf.svg` (2026-11-12, the user's
            // call; the green-tile app icon before, with a green shadow that
            // glowed on the dark page).
            Image("LeafMark")
                .resizable()
                .scaledToFit()
                .frame(height: isRegular ? 150 : 104)
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [StartPage.glow.opacity(0.045), StartPage.glow.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: isRegular ? 230 : 160))
                        .frame(width: isRegular ? 460 : 320, height: isRegular ? 460 : 320)
                        .offset(y: isRegular ? 50 : 36)
                        .allowsHitTesting(false)
                }

            // Bold with tightened tracking: ExtraBold at default spacing
            // crowded its letters at this size. (A serif wordmark was tried
            // and undone, 2026-11-08: the name was fine as it was.)
            VStack(spacing: 6) {
                Text("Evlin")
                    .font(Typography.font(isRegular ? 46 : 34, weight: .bold))
                    .tracking(isRegular ? -1.1 : -0.8)
                    .foregroundStyle(Brand.ink)
                // The app's philosophy, the user's words: keep it.
                Text("Ever learning, ever kind.")
                    .font(Typography.font(isRegular ? 20 : 17, weight: .medium))
                    .foregroundStyle(Brand.inkSoft)
            }
            .padding(.top, isRegular ? 28 : 20)

            VStack(spacing: isRegular ? 14 : 12) {
                ForEach(AppMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        StartModeLabel(mode: m, isRegular: isRegular)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Wider on the iPad (2026-11-16, the user's call; 420 before).
            .frame(maxWidth: isRegular ? 560 : 300)
            .padding(.horizontal, 24)
            .padding(.top, isRegular ? 56 : 44)
            Spacer()
            Spacer()
                .frame(maxHeight: isRegular ? 60 : 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The app's cream by day, as the opening splash, with no grain
        // (2026-11-14, the user's call: the onboarding's e-paper, #F1EFE9,
        // read grey); the setup's blue charcoal at night.
        .background(StartPage.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: mode)
    }
}
