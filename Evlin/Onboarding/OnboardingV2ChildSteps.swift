import SwiftUI
import UIKit
import FamilyControls
import UserNotifications

// Onboarding v2 — KID-side screens, ported from the real app's
// Child/V2/ChildV2PlaceholderSteps.swift plus the reused legacy screens
// (GrantPermissionStep, DeletionProtectionStep, ChildReadyStep). Screen Time
// authorization (FamilyControls) and push permission (UserNotifications) are
// real system calls (see ChildScreenTimeStep / ChildNotificationsStep); the
// pairing chain (ChildShowCodeStep) polls the real backend. What's still a
// timed stand-in rather than a real check is called out at each site
// instead of blanket-claimed here.

private let childTotal = 11
private let kidGreen = OnboardingV2Theme.Palette.secondary

// MARK: - 3 · Profile (kid)

struct ChildProfileStep: View {
    @Binding var name: String
    @Binding var ageRange: String?
    @Binding var gender: String?
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    private let genderOptions: [(label: String, key: String)] =
        [("Female", "female"), ("Male", "male"), ("Other", "other")]

    // A coarse age bracket instead of an exact birthdate — the app only
    // ever needed a rough age signal downstream, so asking a kid to pick a
    // bucket is both simpler to answer and less data than a full DOB.
    private let ageRangeOptions = ["4-6", "7-9", "10-12", "13-17"]
    @State private var ageRangeIndex = 0
    @State private var genderIndex = 0

    private var canContinue: Bool {
        // Needs a letter: a name that's only digits is almost always the
        // pairing code typed into the wrong box.
        name.contains(where: \.isLetter)
    }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 13) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").onboardingV2FieldLabel()
                        OnboardingV2FieldBox {
                            TextField("Your child's name", text: $name)
                                .font(Evlin.Typography.font(isRegular ? 19 : 16, weight: .semibold))
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                                .tint(kidGreen)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                // Return goes on, so the keyboard never
                                // stands between the kid and the next step.
                                .submitLabel(.continue)
                                .onSubmit { if canContinue { onContinue() } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Age").onboardingV2FieldLabel()
                        OnboardingV2Segmented(options: ageRangeOptions, selectedIndex: $ageRangeIndex)
                            .onChange(of: ageRangeIndex, initial: true) { _, i in
                                ageRange = ageRangeOptions[i]
                            }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gender").onboardingV2FieldLabel()
                        OnboardingV2Segmented(options: genderOptions.map(\.label), selectedIndex: $genderIndex)
                            .onChange(of: genderIndex, initial: true) { _, i in
                                gender = genderOptions[i].key
                            }
                    }
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                    .disabled(!canContinue)
            }
        )
    }
}

// MARK: - 6 · Show code (kid)

/// The kid's device asks the backend for a pairing code and shows it as a QR
/// and as digits. A parent scans/types it in their app; this screen polls
/// until that happens, then keeps the device token it is handed.
struct ChildShowCodeStep: View {
    var childName: String = ""
    let onConnected: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var code: String?
    @State private var errorText: String?

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 1,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("Parents: Connect This Device")
                            .onboardingV2TitleL()
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                    }

                    if let code {
                        OnboardingV2QRImage(string: OnboardingV2PairPayload.encode(code: code), side: 200)
                        Text(code)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for parent to connect…")
                                .onboardingV2BodyXS()
                        }
                    } else if errorText == nil {
                        ProgressView("Getting your code…")
                    }

                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            },
            footer: { }
        )
        // Cancelled when the screen goes away, which also stops the polling.
        .task { await run() }
    }

    @MainActor
    private func run() async {
        if DemoPairBridge.isOn {
            // Two simulators linked by `scripts/demo-pair.sh`: wait for the
            // parent's phone to type this code.
            code = DemoPairBridge.startPairing()
            while !Task.isCancelled {
                if DemoPairBridge.read()?.paired == true { onConnected(); return }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            return
        }
        if DemoMode.isBuild {
            code = "482913"
            // Walking through onboarding: a parent "scans" after a moment.
            if DemoMode.previewsOnboarding {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !Task.isCancelled { onConnected() }
            }
            return
        }
        while !Task.isCancelled {
            do {
                let request = try await APIClient.shared.requestPairing(childName: childName)
                code = request.code
                errorText = nil
                // Codes last 15 minutes; poll until claimed, then start over if it lapses.
                for _ in 0..<440 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    do {
                        if try await APIClient.shared.pairingStatus(code: request.code, secret: request.secret) != nil {
                            onConnected()
                            return
                        }
                    } catch let f as APIFailure where f.status == 404 {
                        break // expired: get a fresh code
                    } catch {
                        // Transient network trouble: keep the same code and keep polling.
                    }
                }
            } catch {
                code = nil
                errorText = "Couldn't reach the server. Retrying…"
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}

// MARK: - 7 · Connected (kid)

struct ChildConnectedStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 2,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 16) {
                    Spacer(minLength: 8)
                    // The same leaf approved badge as the parent's Connected.
                    LeafApprovedBadge(size: 128)
                    Text("Connected").onboardingV2TitleL()
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
            }
        )
    }
}

// MARK: - 9 · Screen Time access (split out from the old combined
// "Grant access" list screen into its own full-screen step — matches the
// parent chain's native-permission-dialog treatment (ParentNotificationsAskStep)
// instead of a compact row. "Prevent app deletion" is dropped entirely: it's
// already communicated on the parent side via ParentSetPasscodeV2Step's
// "Also stops [kid] from deleting Evlin" badge, so repeating it here as a
// third checkbox was redundant.)

struct ChildScreenTimeStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    private enum Stage: Equatable { case initial, requesting, granted, denied(String) }
    @State private var stage: Stage = .initial
    @State private var showingSimulatorAuthorization = false
    // Was `= AuthorizationCenter.shared.authorizationStatus` — a live read
    // of FamilyControls' system authorization state used directly as this
    // @State's default value, which runs synchronously while SwiftUI is
    // still constructing this view (i.e. on the main thread, before this
    // screen has drawn anything at all). On a genuinely fresh install,
    // that's this process's first-ever touch of the FamilyControls system
    // daemon, which is a real, sometimes-slow XPC round-trip to spin up —
    // exactly the kind of "blocking work in view init" that stalls the
    // whole app right at this screen. Force-quitting and relaunching
    // "fixed" it only because the daemon connection was already warm on
    // the second attempt. Reading it in .task below instead defers that
    // same call until after this screen has already appeared, matching
    // this project's own established pattern of deferring possibly-slow
    // first-run work off the construction path.
    @State private var authStatus: AuthorizationStatus = .notDetermined

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "4 · Access",
            stepIndex: 6,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                GeometryReader { geometry in
                    let landscape = geometry.size.width > geometry.size.height
                    let artSize = min(landscape ? geometry.size.height * 0.48 : geometry.size.width * 0.44,
                                      landscape ? 360 : 320)

                    Group {
                        if landscape {
                            HStack(spacing: min(geometry.size.width * 0.08, 96)) {
                                illustration(size: artSize)
                                    .frame(maxWidth: geometry.size.width * 0.38)
                                stageCard(isLandscape: true)
                                    .frame(maxWidth: 580)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 48)
                        } else {
                            VStack(spacing: 28) {
                                Spacer(minLength: 16)
                                illustration(size: artSize)
                                stageCard(isLandscape: false)
                                    .frame(maxWidth: 640)
                                Spacer(minLength: 16)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 32)
                        }
                    }
                }
            },
            footer: { screenTimeAction }
        )
        .animation(.easeOut(duration: 0.2), value: stage)
        .alert("Allow Screen Time Access?", isPresented: $showingSimulatorAuthorization) {
            Button("Don't Allow", role: .cancel) {}
            Button("Allow", action: onContinue)
        }
        .task {
            // Read on the main actor (where AuthorizationCenter lives) so
            // there is no cross-actor hop and no unsafeForcedSync. The
            // previous DispatchQueue.global() approach accessed a @MainActor
            // property from a background queue, which forced the runtime to
            // synchronously hop back — blocking the main thread and stalling
            // gesture recognizers for tens of seconds on first launch.
            authStatus = AuthorizationCenter.shared.authorizationStatus
            if authStatus == .approved {
                stage = .granted
            }
        }
    }

    // Before access is given: a small copy of Apple's Screen Time alert with
    // a finger tapping Continue, so the parent knows what to press when the
    // real one appears (as Opal does). After: nothing, just
    // the check and "Access granted" below.
    @ViewBuilder
    private func illustration(size: CGFloat) -> some View {
        if stage != .granted {
            OnboardingV2SystemAlertHint.screenTime(width: min(size * 1.15, 340))
        }
    }

    @ViewBuilder
    private func stageCard(isLandscape: Bool) -> some View {
        VStack(alignment: isLandscape ? .leading : .center, spacing: 14) {
            switch stage {
            case .initial, .requesting:
                Text("Evlin Needs Screen Time Access")
                    .onboardingV2TitleL()
                    .multilineTextAlignment(isLandscape ? .leading : .center)
                Text("On the next screen, tap Continue.")
                    .onboardingV2Body()
                    .multilineTextAlignment(isLandscape ? .leading : .center)
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(kidGreen)
                Text("Access granted")
                    .onboardingV2TitleL()
                    .multilineTextAlignment(isLandscape ? .leading : .center)
            case .denied(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(OnboardingV2Theme.Palette.tertiary)
                Text("Access not granted")
                    .onboardingV2TitleL()
                    .multilineTextAlignment(isLandscape ? .leading : .center)
                Text(message)
                    .onboardingV2Body()
                    .multilineTextAlignment(isLandscape ? .leading : .center)
                    // Really retries AuthorizationCenter — this used to just
                    // force `stage = .granted` without asking again, so a
                    // real denial (or a "set a device passcode first"
                    // failure, even after the kid went and set one) always
                    // read as granted regardless of the real system state.
                    // That let onboarding continue into ChildLockableHubStep
                    // believing FamilyControls was authorized when it might
                    // not be, which is the one thing everything downstream
                    // (app-picking, enforcement) actually depends on. Note:
                    // Screen Time authorization is known to fail/hang on the
                    // Simulator — this makes that failure honest instead of
                    // papering over it, so kid-side Simulator testing may
                    // need a real device for this one step.
            }
        }
        .frame(maxWidth: .infinity, alignment: isLandscape ? .leading : .center)
    }

    @ViewBuilder
    private var screenTimeAction: some View {
        Group {
            switch stage {
            case .initial, .requesting:
                if DemoMode.previewsOnboarding {
                    OnboardingV2PrimaryButton("Grant", role: .child) {
                        showingSimulatorAuthorization = true
                    }
                } else {
                    OnboardingV2PrimaryButton(stage == .requesting ? "Requesting…" : "Grant", role: .child) {
                        Task { await requestScreenTime() }
                    }
                    .disabled(stage == .requesting)
                }
            case .granted:
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
            case .denied:
                OnboardingV2PrimaryButton("Try Again", systemImage: "arrow.clockwise", role: .child) {
                    Task { await requestScreenTime() }
                }
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func requestScreenTime() async {
        stage = .requesting
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            stage = .granted
        } catch {
            let msg: String
            if "\(error)".contains("restricted") {
                msg = "Screen Time is restricted on this device."
            } else if "\(error)".contains("authenticationMethodUnavailable") {
                msg = "Set a device passcode first, then try again."
            } else {
                msg = "Authorization failed: \(error.localizedDescription)"
            }
            stage = .denied(msg)
        }
    }
}

// MARK: - 10 · Notifications ask (kid device) — mirrors the parent chain's
// ParentNotificationsAskStep exactly (the native "Would Like to Send You
// Notifications" dialog card over a Lottie illustration), re-themed for
// kid mode rather than the old compact list-row treatment.

struct ChildNotificationsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    @State private var requesting = false

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "4 · Access",
            stepIndex: 7,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    OnboardingV2NotificationPrompt()
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        OnboardingV2PrimaryButton("Allow", role: .child) {
                            Task { await requestThenAdvance() }
                        }
                        .disabled(requesting)
                        .frame(maxWidth: 600)
                    }
                    .frame(maxWidth: .infinity)
                }
            },
            footer: {            }
        )
    }

    @MainActor
    private func requestThenAdvance() async {
        requesting = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        requesting = false
        onContinue()
    }
}

// MARK: - 12 · Choose what to lock

struct ChildLockableHubStep: View {
    // Lazy: created on first picker open, not during view construction.
    // FamilyActivitySelection() triggers a synchronous XPC call to the
    // FamilyControls daemon — on a first install the daemon is cold and
    // that call can block the main thread for tens of seconds, freezing
    // the entire app. Keeping it nil until the user taps "Choose Apps"
    // defers that cost to a moment where a brief spinner is expected.
    @State private var selection: FamilyActivitySelection?
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var showPicker = false
    // FamilyActivityPicker only ever reports a selection back with real,
    // granted Screen Time authorization — on the Simulator that's a
    // platform limitation with no in-app workaround (Screen Time's backing
    // daemons don't run there), so `selection` can stay empty even after a
    // kid genuinely opens the picker and taps apps in it. Gating Continue
    // on having opened the picker at least once, not strictly on a nonzero
    // selection, means the real picker is always what's shown — never a
    // substitute — while still not permanently dead-ending here in an
    // environment that can't report back what was picked.
    @State private var pickerOpenedOnce = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var totalSelected: Int {
        guard let selection else { return 0 }
        return selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
    }

    // One button, which moves on with the step: it opens the picker until
    // something is picked, then reads Continue. What was picked shows in a
    // card above it, with Change to open the picker again.
    private var hasPicked: Bool {
        #if targetEnvironment(simulator)
        // The picker reports nothing back on the Simulator, so opening it
        // has to count, or setup can't go on there.
        return totalSelected > 0 || pickerOpenedOnce
        #else
        return totalSelected > 0
        #endif
    }

    private func openPicker() {
        if selection == nil { selection = FamilyActivitySelection() }
        showPicker = true
        pickerOpenedOnce = true
    }

    private var selectionSummary: String {
        guard let selection else { return "" }
        var parts: [String] = []
        let apps = selection.applicationTokens.count
        let categories = selection.categoryTokens.count
        let sites = selection.webDomainTokens.count
        if apps > 0 { parts.append(apps == 1 ? "1 app" : "\(apps) apps") }
        if categories > 0 { parts.append(categories == 1 ? "1 category" : "\(categories) categories") }
        if sites > 0 { parts.append(sites == 1 ? "1 website" : "\(sites) websites") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "4 · Lockable",
            stepIndex: 8,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 20) {
                    LockingAppsArt()
                        .frame(width: hSizeClass == .regular ? 300 : 220, height: hSizeClass == .regular ? 300 : 220)
                        .accessibilityHidden(true)

                    Text("Choose Apps to Lock")
                        .onboardingV2TitleL()
                        .multilineTextAlignment(.center)

                    // What was picked, on one line, with Change beside it.
                    if hasPicked {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(kidGreen)
                            Text(totalSelected > 0 ? selectionSummary : "Apps chosen")
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                            Button("Change", action: openPicker)
                                .fontWeight(.bold)
                                .foregroundStyle(kidGreen)
                                .padding(.leading, 4)
                        }
                        .font(Evlin.Typography.font(16, weight: .semibold))
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: hasPicked)
            },
            footer: {
                if hasPicked {
                    OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                } else {
                    OnboardingV2PrimaryButton("Choose Apps & Categories", role: .child, action: openPicker)
                }
            }
        )
        .familyActivityPicker(
            isPresented: $showPicker,
            selection: Binding(
                get: { selection ?? FamilyActivitySelection() },
                set: { selection = $0 }
            )
        )
    }
}

/// A grid of app tiles popping in one after another, then small padlocks
/// dropping onto some of them as those apps dim: what this step does.
/// Flat 2D shapes, played once; Reduce Motion shows it finished.
private struct LockingAppsArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilesIn = false
    @State private var locksIn = false

    private static let apps: [(icon: String, color: String)] = [
        ("gamecontroller.fill", "A86BFF"), ("play.rectangle.fill", "FF5A5F"), ("music.note", "FF8A3D"),
        ("message.fill", "3FCE64"), ("camera.fill", "4D9CFF"), ("paintbrush.pointed.fill", "FF6B9A"),
        ("book.fill", "14B8A6"), ("globe", "4D9CFF"), ("star.fill", "FFC93C"),
    ]
    /// Which tiles get a lock.
    private static let locked: Set<Int> = [0, 1, 4, 5, 7]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let gap = side * 0.06
            let tile = (side - gap * 2) / 3
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.apps.count, id: \.self) { i in
                    let row = i / 3, col = i % 3
                    let isLocked = Self.locked.contains(i)
                    let lockOrder = Array(Self.locked.sorted()).firstIndex(of: i) ?? 0
                    RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous)
                        .fill(Color(hex: Self.apps[i].color))
                        .overlay(
                            Image(systemName: Self.apps[i].icon)
                                .font(.system(size: tile * 0.4, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .saturation(isLocked && locksIn ? 0.35 : 1)
                        .opacity(isLocked && locksIn ? 0.7 : 1)
                        .animation(.easeOut(duration: 0.3).delay(0.75 + Double(lockOrder) * 0.12), value: locksIn)
                        .overlay(alignment: .bottomTrailing) {
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: tile * 0.22, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .frame(width: tile * 0.42, height: tile * 0.42)
                                    .background(Circle().fill(Color(hex: "25924A")))
                                    .overlay(Circle().strokeBorder(.white, lineWidth: tile * 0.05))
                                    .offset(x: tile * 0.12, y: tile * 0.12)
                                    .scaleEffect(locksIn ? 1 : 0.1)
                                    .offset(y: locksIn ? 0 : -tile * 0.5)
                                    .opacity(locksIn ? 1 : 0)
                                    .animation(.spring(duration: 0.35, bounce: 0.5).delay(0.75 + Double(lockOrder) * 0.12), value: locksIn)
                            }
                        }
                        .frame(width: tile, height: tile)
                        .scaleEffect(tilesIn ? 1 : 0.2)
                        .opacity(tilesIn ? 1 : 0)
                        .animation(.spring(duration: 0.4, bounce: 0.4).delay(Double(i) * 0.05), value: tilesIn)
                        .offset(x: CGFloat(col) * (tile + gap), y: CGFloat(row) * (tile + gap))
                }
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            if reduceMotion {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { tilesIn = true; locksIn = true }
            } else {
                tilesIn = true
                locksIn = true
            }
        }
    }
}

// MARK: - 12b · Family Sharing check

// A Family Sharing child account can't approve its own Screen Time changes
// without the organizer — the in-app PIN step is only needed as a stand-in
// for families that don't have that native protection.
struct ChildFamilySharingAskStep: View {
    let onYes: () -> Void
    let onNo: () -> Void
    var onBack: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }
    @State private var tapCount = 0

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "3 · Safety",
            stepIndex: 4,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                // The mark, bigger, right beside the question in two calm
                // lines, the pair centred (2026-11-15, the user's call; the
                // mark above a left-aligned question before). On a phone,
                // with no room beside it, the mark sits above, centred.
                Group {
                    if isRegular {
                        HStack(spacing: 32) {
                            FamilyMark(size: 150, animated: false)
                            question
                                .font(Typography.font(36, weight: .semibold))
                                .tracking(-0.4)
                                .lineSpacing(6)
                                .multilineTextAlignment(.leading)
                        }
                    } else {
                        VStack(spacing: 22) {
                            FamilyMark(size: 104, animated: false)
                            question
                                .font(Typography.font(24, weight: .semibold))
                                .tracking(-0.2)
                                .lineSpacing(4)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            },
            // Yes and No side by side at the foot of the page, where
            // Continue sits, round-ended pills: Yes solid green, No soft grey
            // (2026-11-16, the user's calls; both the same bright green just
            // before; stacked Yes over No just
            // before; centred under the question with Yes an outlined
            // button, 2026-11-15, before that).
            footer: {
                HStack(spacing: isRegular ? 16 : 12) {
                    answer("Yes", primary: true, action: onYes)
                    answer("No", primary: false, action: onNo)
                }
                .frame(maxWidth: OnboardingV2Theme.Metrics.ctaMaxWidth)
                .frame(maxWidth: .infinity)
            }
        )
    }

    /// The user's sentence (2026-11-14), in two lines: semibold, a soft
    /// charcoal, open tracking (2026-11-15, the user's call: "too harsh";
    /// bold, 56 / 32pt, tight, near-black before).
    private var question: some View {
        Text(isRegular ? "Do you use Family Sharing to control\nyour children’s screen time?"
                       : "Do you use Family Sharing to control your children’s screen time?")
            .foregroundStyle(Color(light: "34373D", dark: "E6E8EC", warm: "E6E8EC"))
            .lineLimit(isRegular ? 2 : 4)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The answers, side by side at the foot of the page, each the size,
    // corners and type of Continue (2026-11-15, the user's calls; soft grey
    // pills, side by side at the foot, full-width cards with an arrow, and
    // rows between hairlines, before).
    private var answerShape: Capsule { Capsule(style: .continuous) }

    /// Yes, the primary: a fresh mid green, #34B85A, solid with white
    /// words (setup's #3FCE64 was tried the same day and was harsher).
    /// No, the secondary: a bright warm grey, #F5F5F1, a breath under the
    /// page, with a firm #CFCFC8 edge so it reads clearly, and the
    /// heading's dark #2C2C2E (the user's call: brighter; #EDEDE8 just
    /// before, and #F0F0EC with a faint #DCDCD6 edge before that). Both semibold
    /// (2026-11-16, the user's call: brighter and easier on the eyes; just
    /// before, Yes the main app's deeper #2FA84F and No #EAEAE6 with no
    /// edge, heavy words; Apple's cool #EFEFF4 with #34373D before that) (2026-11-16, the user's call: two identical
    /// bright pills side by side strained the eyes and made a wrong tap
    /// easy, and the electric green vibrated on the off-white). Both were
    /// a punchy #22D163 just before (2026-11-15: "make the Yes and No
    /// brighter"); before that No was the solid one and Yes the page's
    /// colour with a green edge (a vivid mint, a paler mint, the setup
    /// picks' sage, a light grey and the Child's pastel #A4E3AA before).
    /// The app's one button green since 2026-11-16 (#34B85A before).
    private static let yesFill = OnboardingV2Theme.Palette.button
    private static let noFill = Color(light: "F5F5F1", dark: "2A2E35", warm: "2A2E35")
    private static let noInk = Color(light: "2C2C2E", dark: "E6E8EC", warm: "E6E8EC")
    private static let noEdge = Color(light: "CFCFC8", dark: "353A42", warm: "353A42")

    private func answer(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            tapCount += 1
            action()
        } label: {
            // Just the word (2026-11-09: "We already use it" and "Set up
            // without it" under them were removed).
            // Semibold, not heavy: thick white letters on a strong fill
            // tired the eyes (2026-11-16).
            Text(title)
                .font(Typography.font(isRegular ? 21 : 15, weight: .semibold))
                .foregroundStyle(primary ? Color.white : Self.noInk)
                .frame(maxWidth: .infinity)
                .frame(height: isRegular ? OnboardingV2Theme.Metrics.ctaHeightRegular : OnboardingV2Theme.Metrics.ctaHeightCompact)
                .background(primary ? Self.yesFill : Self.noFill, in: answerShape)
                .overlay(answerShape.strokeBorder(primary ? .clear : Self.noEdge, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilySharingAnswerStyle())
        .sensoryFeedback(.selection, trigger: tapCount)
    }
}

/// A Yes / No button: dims a touch while pressed.
private struct FamilySharingAnswerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 12c · No Family Sharing yet

// Shown to families who said they don't use Family Sharing. Read like a
// short article with a plain title, a lead paragraph, then four short
// headings. Setting it up is the main button; the Screen Time PIN stays as
// the quick way through.
struct ChildLockChoiceStep: View {
    let kidName: String
    let onFamilySharing: () -> Void
    let onPIN: () -> Void
    var onBack: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showQuickWarning = false

    private var isRegular: Bool { hSizeClass == .regular }

    private var kid: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your child" : trimmed
    }

    private struct Section: Identifiable {
        let id: Int
        let icon: String
        /// The tile, as Apple draws that feature's icon in Settings.
        let tile: [Color]
        let heading: String
        let detail: String?
    }

    private var sections: [Section] {
        [
            Section(id: 0, icon: "app.badge.checkmark.fill",
                    tile: [Color(hex: "1EC2FB"), Color(hex: "1572F6")],
                    heading: "You approve every download",
                    detail: nil),
            Section(id: 1, icon: "trash.slash.fill",
                    tile: [Color(hex: "FF6A60"), Color(hex: "FF3B30")],
                    heading: "Apps stay where you put them",
                    detail: nil),
            Section(id: 2, icon: "hourglass",
                    tile: [Color(hex: "7D7AF0"), Color(hex: "5452D8")],
                    heading: "Screen Time can't be switched off",
                    detail: nil),
            // "Worth having with or without Evlin" was a fourth, removed
            // 2026-11-12 (the user's call).
        ]
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "3 · Safety",
            stepIndex: 5,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                article
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity)
            },
            footer: {
                VStack(spacing: 10) {
                    OnboardingV2PrimaryButton("Set up Family Sharing", role: .child, action: onFamilySharing)
                    // "Quick setup" with a warning sign, and a warning before
                    // it goes on (2026-11-10, the user's call; "Maybe later"
                    // went straight to the PIN before).
                    OnboardingV2SecondaryButton("Quick setup",
                                                systemImage: "exclamationmark.triangle.fill",
                                                imageTint: QuickSetupWarning.amber) {
                        showQuickWarning = true
                    }
                }
            }
        )
        .sheet(isPresented: $showQuickWarning) {
            QuickSetupWarning(
                onFamilySharing: { showQuickWarning = false; onFamilySharing() },
                onContinue: { showQuickWarning = false; onPIN() }
            )
            .presentationDetents([.height(isRegular ? 440 : 400)])
            .presentationDragIndicator(.visible)
            .presentationBackground(OnboardingV2Theme.Palette.paper)
            .fittedOnIPad()
        }
    }

    private var article: some View {
        VStack(alignment: .leading, spacing: 0) {
            FamilyMark(size: isRegular ? 78 : 66, animated: false)
                .padding(.bottom, isRegular ? 24 : 20)
            Text("Set up Family Sharing")
                // A little bigger (2026-11-12, the user's ask; 35 / 29 before).
                .font(Typography.font(isRegular ? 39 : 31, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                .padding(.bottom, 10)
            Text("Family Sharing is provided by Apple and is free to use. Its protections can help your family even if you stop using Evlin.")
                // A little bigger (2026-11-12; 22 / 20 before).
                .font(Typography.font(isRegular ? 25 : 21, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, isRegular ? 30 : 24)
            VStack(alignment: .leading, spacing: isRegular ? 26 : 22) {
                ForEach(sections) { section($0) }
            }
        }
    }

    private func section(_ s: Section) -> some View {
        let tile = isRegular ? 38.0 : 34.0
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: s.icon)
                .font(.system(size: isRegular ? 18 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(LinearGradient(colors: s.tile, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.heading)
                    .font(Typography.font(isRegular ? 19 : 17.5, weight: .semibold))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                if let detail = s.detail {
                    Text(detail)
                        .font(Typography.font(isRegular ? 16 : 15, weight: .regular))
                        .lineSpacing(3)
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, isRegular ? 6 : 5)
        }
    }
}

/// Quick setup's warning, a half card: without Family Sharing kids can get
/// around the safety features. Set up Family Sharing goes to its steps;
/// Continue anyway goes on to the Screen Time PIN.
struct QuickSetupWarning: View {
    let onFamilySharing: () -> Void
    let onContinue: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    static let amber = Color(light: "E08A1E", warm: "F2AE6C")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Self.amber)
                .frame(width: 48, height: 48)
                .background(Self.amber.opacity(0.16), in: Circle())
            Text("Reduce the risk of bypasses")
                .font(Typography.font(isRegular ? 24 : 21, weight: .bold))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            Text("Without Family Sharing, children may be able to bypass some protections on their device. Family Sharing adds safeguards that can reduce that risk. It's Apple's free service, and you can keep using it with Screen Time or another parental-control app even if Evlin isn't the right fit for your family.")
                .font(Typography.font(isRegular ? 20 : 19, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                OnboardingV2PrimaryButton("Set up Family Sharing", role: .child, action: onFamilySharing)
                Button(action: onContinue) {
                    Text("Continue anyway")
                        .font(Typography.font(isRegular ? 17 : 15.5, weight: .semibold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, isRegular ? 36 : 24)
        .padding(.top, 28)
        .padding(.bottom, isRegular ? 24 : 12)
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private extension View {
    /// On the iPad a sheet is a centred form; fit it to the card's height
    /// (iOS 18) rather than leave a tall empty panel.
    @ViewBuilder func fittedOnIPad() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.form.fitted(horizontal: false, vertical: true))
        } else {
            self
        }
    }
}

// MARK: - 12d · Family Sharing setup

// Only instructions: there's no API to check Family Sharing membership, so
// "I've set it up" is taken on trust, same as the PIN step. No PIN option
// here (removed 2026-11-11, the user's call): the PIN is Quick setup's, on
// the page before.
struct ChildFamilySharingSetupStep: View {
    let kidName: String
    let onDone: () -> Void
    var onBack: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }
    /// First what to do on the parent's iPhone, then back here on the iPad
    /// (2026-11-09, the user's sequence).
    @State private var onIPad = false
    /// When Back last returned to the account steps.
    @State private var backAt: Date?
    /// Back in Evlin after Open Settings on the sign-in page.
    @State private var signInCameBack = false
    /// Open Settings was tapped: only a return after it counts (2026-11-12:
    /// any return, Control Center included, showed "signed in" too soon).
    @State private var wentToSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private var kid: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your child" : trimmed
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "3 · Safety",
            stepIndex: 5,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: {
                if onIPad {
                    withAnimation(.smooth(duration: 0.3)) { onIPad = false }
                } else {
                    FamilySharingHandOff.kidLeaves()
                    onBack?()
                }
            },
            // The steps are a list (2026-11-12): its bar stays in view.
            scrollBar: true,
            content: {
                Group {
                    if onIPad { lookAtIPhone } else { createAccount }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, isRegular ? 24 : 16)
            },
            footer: {
                VStack(spacing: 10) {
                    if onIPad {
                        signInButtons
                    } else {
                        // The steps scroll above it (2026-11-12, the user's
                        // call); "Done, next step" and Back turning a
                        // carousel one step at a time came before.
                        OnboardingV2PrimaryButton("I've created the account", role: .child) {
                            withAnimation(.smooth(duration: 0.3)) { onIPad = true }
                        }
                    }
                }
            }
        )
        // The parent's phone follows: on the account steps it offers Open
        // Settings and "I've created the account"; at step 2 it shows the
        // sign-in steps.
        .onAppear { if !onIPad { FamilySharingHandOff.kidCreatingAccount() } }
        // Back from Settings on the sign-in page: the account's signed in.
        .onChange(of: scenePhase) { old, now in
            // Leaving Evlin any way counts, not only through Open Settings
            // (2026-11-13, the user's catch: going home and into Settings by
            // hand left only Open Settings here). Control Center never
            // reaches the background, so it still doesn't count.
            // Having left Evlin (Open Settings, or home to Settings by hand),
            // coming back turns the one button into "Mia's account is signed
            // in"; it still waits for the tap (2026-11-13, the user's call).
            // Control Center never reaches the background, so it doesn't count.
            if now == .background, onIPad { wentToSettings = true }
            if now == .active, old != .active, onIPad, wentToSettings {
                withAnimation(.smooth(duration: 0.3)) { signInCameBack = true }
            }
        }
        .onChange(of: onIPad) { _, now in
            signInCameBack = false
            wentToSettings = false
            if now { FamilySharingHandOff.kidAccountCreated() } else {
                backAt = Date()
                FamilySharingHandOff.kidCreatingAccount()
            }
        }
        // "I've created the account" tapped on the parent's phone moves this
        // on too (2026-11-11, the user's call: either device's tap).
        .task(id: onIPad) {
            guard !onIPad else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: DemoPairBridge.isOn ? 700_000_000 : 2_000_000_000)
                guard !Task.isCancelled, !onIPad else { return }
                // Just back from step 2, the server may still have the old
                // stage for a moment.
                if let backAt, Date().timeIntervalSince(backAt) < 8 { continue }
                if await FamilySharingHandOff.kidReadsStage() == .accountCreated {
                    withAnimation(.smooth(duration: 0.3)) { onIPad = true }
                    return
                }
            }
        }
    }

    /// Step 1, on the iPad: how the parent makes the child's Apple Account
    /// on their iPhone, played here (2026-11-10, the user's words: follow
    /// these steps, Settings, Family, create a child account).
    // One calm line of instructions over it (2026-11-10, the user's ask:
    // follow the steps, swipe through them).
    private var createAccount: some View {
        VStack(spacing: 14) {
            // Their own phone, not this iPad, and out of Evlin (2026-11-10, the
            // user's call: "Follow these steps on your iPhone" wasn't clear).
            // Grab the phone and leave Evlin there (2026-11-11, the user's
            // wording; "Do these steps on your own iPhone." before).
            // "your iPhone" stands out: it's the parent's phone, not this
            // device (2026-11-12, the user's ask).
            // Words only: which phone, and why (2026-11-13, the user's
            // wording; a pill and then an iPad → iPhone drawing over it
            // were tried the same day and removed).
            // "your iPhone" bold and green, the steps' own green (2026-11-13,
            // the user's call: highlight it).
            hint("Grab **your iPhone**—not your child’s device—and follow the instructions shown below.", accent: true)
            FamilySharingStepList(kidName: kid)
                .padding(.top, isRegular ? 12 : 6)
        }
        .padding(.top, isRegular ? 4 : 8)
    }

    /// Step 2, once the account's made: this page holds still, no
    /// animation, and the parent's iPhone, waiting in Evlin, shows how to
    /// sign this iPad in with the new account (2026-11-11, the user's call;
    /// the iPad played its own sign-in steps before).
    // Sign in here, in Settings, following the iPhone's steps; plain
    // orders, no "Not sure how?" (2026-11-11, the user's wording; "Grab your iPhone" /
    // "Open Evlin on it to see how to sign this iPad in" before).
    private var lookAtIPhone: some View {
        // The same two steps as the parent's iPhone, under one line: the
        // child's account, not the parent's own (2026-11-12, the user's
        // call; a gear, "Sign this iPad in" and a line before).
        VStack(spacing: 14) {
            // Sign out of any other account first; "not your own" confused
            // parents (2026-11-12, the user's call).
            // Signing out is step 1's (2026-11-12); coming back is said first,
            // so it's known before leaving for Settings (2026-11-13).
            hint("Sign this iPad in as **\(kid)**, then come back to Evlin.")
            FamilySharingStepList(kidName: kid, part: .iPad, onThatDevice: true)
                .padding(.top, isRegular ? 12 : 6)
        }
        .padding(.top, isRegular ? 4 : 8)
    }

    private var signedInWords: String {
        // No name known: not "Your child's account …" (2026-11-12).
        kid == "your child" ? "The child account is signed in"
            : "\(kid.prefix(1).uppercased() + kid.dropFirst())'s account is signed in"
    }

    private func signedIn() {
        // The parent's phone hears it and says so (2026-11-12).
        FamilySharingHandOff.kidSignedIn()
        onDone()
    }

    /// Step 2's one button (2026-11-13, the user's call): Open Settings,
    /// which becomes "Mia's account is signed in" once the parent has left
    /// Evlin and come back. Tried the same day: both side by side; coming
    /// back moving on by itself. Apps can only open their own page in
    /// Settings (its other pages are private URLs, which App Review
    /// rejects): from there the parent taps "Settings" at the top left,
    /// then Sign in.
    private var signInButtons: some View {
        ZStack {
            if signInCameBack {
                OnboardingV2PrimaryButton(signedInWords, role: .child, action: signedIn)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                OnboardingV2PrimaryButton("Open Settings", systemImage: "gearshape", role: .child, action: openSettings)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: signInCameBack)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        wentToSettings = true
        UIApplication.shared.open(url)
    }

    /// A line of plain orders; its **bold** words in the page's own ink.
    private func hint(_ text: String, accent: Bool = false) -> some View {
        Text(hintStyled(text, accent: accent))
            // Bigger (2026-11-10, the user's call; 18 / 15.5 before).
            .font(Typography.font(isRegular ? 24 : 18, weight: .medium))
            .lineSpacing(4)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
            .multilineTextAlignment(.center)
            // Wide enough on the iPad for each sentence on its own line.
            .frame(maxWidth: isRegular ? 720 : 520)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
    }

    private func hintStyled(_ text: String, accent: Bool = false) -> AttributedString {
        var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].font = Typography.font(isRegular ? 24 : 18, weight: .bold)
            a[run.range].foregroundColor = accent ? OnboardingV2Theme.Palette.secondary : OnboardingV2Theme.Palette.onSurface
        }
        return a
    }
}

// MARK: - 11 · All set (reused legacy screen)

struct ChildOnboardingReadyStep: View {
    let onEnter: () -> Void
    // Same reasoning as ParentOnboardingDoneStep: this doesn't route
    // through OnboardingV2ScreenContainer, so it needs its own iPad cap to
    // avoid stretching the CTA edge to edge across the tablet's width.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        VStack(spacing: Spacing.section) {
            // See ParentOnboardingDoneStep's identical comment — flexible
            // Spacers here would absorb an iPad's whole extra height
            // instead of just the leftover sliver an iPhone screen has,
            // stranding this content in a tiny cluster at the top with a
            // huge empty gap before the button.
            if !isRegular { Spacer() }

            // The growing leaf, as on the parent's Habits lane: earth rises, the
            // plant shoots up and opens in its ring (2026-11-09).
            GoalsEmptyStart(action: onEnter, wordsShown: false,
                            plantSize: isRegular ? 210 : 170, gap: KidTheme.background)

            VStack(spacing: Spacing.lg) {
                Text("All set!").onboardingV2TitleXL()
            }

            if !isRegular { Spacer() }

            OnboardingV2PrimaryButton("Enter Evlin", role: .child, action: onEnter)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, isRegular ? Spacing.section : 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: isRegular ? OnboardingV2Theme.Metrics.iPadCenteredMaxWidth : .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // E-paper, warm by night, as the rest of the kid's setup (it was the
        // parent's page colour: black by night).
        .background(EPaperBackground())
    }
}


/// Our own family mark for the Family Sharing question (2026-11-08): a soft
/// round badge with two adults holding a child's hands (an SF Symbol; Apple's
/// own Family Sharing artwork isn't ours to copy). It grows in, then the
/// family gives a small bounce.
struct FamilyMark: View {
    var size: CGFloat
    /// Grows in and bounces; off on both Family Sharing pages, where it
    /// just sits there (2026-11-09).
    var animated = true
    @State private var shown = false
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Family Sharing as iOS shows it in Settings: Apple's family symbol
        // in blue on a white tile (2026-11-09, the user's call; a green round
        // badge before). Built from the SF Symbol: Apple's icon file itself
        // isn't copied into the app.
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "FFFFFF"), Color(hex: "F2F2F7")],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: "figure.2.and.child.holdinghands")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(Color(hex: "0A84FF"))
                .symbolEffect(.bounce, value: bounce)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: size * 0.14, y: size * 0.06)
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion || !animated { shown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { bounce += 1 }
        }
    }
}
