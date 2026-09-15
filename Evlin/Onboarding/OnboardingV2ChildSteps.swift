import SwiftUI
import UIKit
import FamilyControls

// Onboarding v2 — KID-side screens, ported from the real app's
// Child/V2/ChildV2PlaceholderSteps.swift plus the reused legacy screens
// (GrantPermissionStep, DeletionProtectionStep, ChildReadyStep). The source
// versions call FamilyControls (Screen Time authorization), UserNotifications
// (push permission), and a live backend (POST /family/create, the App
// Controls v2 picker, pairing-status polling). None of that exists here —
// every permission "request" and network call is a local @State flip, timed
// with a short `Task.sleep` where the source showed a loading state.

private let childTotal = 11
private let kidGreen = OnboardingV2Theme.Palette.secondary

// MARK: - 3 · Profile (kid)

struct ChildProfileStep: View {
    @Binding var name: String
    @Binding var ageRange: String?
    @Binding var gender: String?
    @Binding var pickedAvatar: UIImage?
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
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    OnboardingV2PhotoAvatarPicker(name: name, pickedImage: $pickedAvatar, accent: kidGreen)
                        .padding(.bottom, 1)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME").onboardingV2FieldLabel()
                        OnboardingV2FieldBox {
                            TextField("Your child's name", text: $name)
                                .font(Evlin.Typography.font(isRegular ? 19 : 16, weight: .semibold))
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                                .tint(kidGreen)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AGE RANGE").onboardingV2FieldLabel()
                        OnboardingV2Segmented(options: ageRangeOptions, selectedIndex: $ageRangeIndex)
                            .onChange(of: ageRangeIndex, initial: true) { _, i in
                                ageRange = ageRangeOptions[i]
                            }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GENDER").onboardingV2FieldLabel()
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

// MARK: - 5/6 · Show code (kid)

struct ChildShowCodeStep: View {
    /// Mocked "family create" — mints a fixed fake code + a real QR after a
    /// short simulated delay, then auto-advances (there's no second device to
    /// scan it in this local-only prototype).
    @Binding var pairingCode: String
    let onConnected: () -> Void
    var onBack: (() -> Void)? = nil

    private var spacedCode: String {
        pairingCode.map(String.init).joined(separator: " ")
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 4,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 12) {
                    OnboardingV2Card {
                        HStack {
                            Spacer(minLength: 0)
                            if pairingCode.isEmpty {
                                OnboardingV2FauxQR()
                            } else {
                                OnboardingV2QRImage(
                                    string: OnboardingV2PairPayload.encode(code: pairingCode))
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    OnboardingV2Card {
                        VStack(spacing: 4) {
                            Text("OR TYPE THIS CODE")
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .tracking(1)
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                            if pairingCode.isEmpty {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                            } else {
                                Text(spacedCode)
                                    .font(Evlin.Typography.font(24, weight: .bold).monospacedDigit())
                                    .tracking(5)
                                    .foregroundStyle(OnboardingV2Theme.Palette.primary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(OnboardingV2Theme.Palette.tertiary)
                            .frame(width: 8, height: 8)
                        Text(pairingCode.isEmpty ? "Generating your code…"
                                                 : "Waiting for parent to scan…")
                            .onboardingV2Body()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            },
            footer: {
            }
        )
        .task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            pairingCode = "482910"
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            onConnected()
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
            stepIndex: 5,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 16) {
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(kidGreen))
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
    @State private var authStatus: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus

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
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ScreenTimeGrantLottieView(size: 190)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    stageCard
                }
            },
            footer: {            }
        )
        .animation(.easeOut(duration: 0.2), value: stage)
        .onAppear {
            if authStatus == .approved {
                stage = .granted
            }
        }
    }

    @ViewBuilder
    private var stageCard: some View {
        VStack(spacing: 0) {
            switch stage {
            case .initial, .requesting:
                Text("Evlin Needs Screen Time Access")
                    .onboardingV2TitleL()
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 6)
                OnboardingV2PrimaryButton(stage == .requesting ? "Requesting…" : "Grant", role: .child) {
                    Task { await requestScreenTime() }
                }
                .disabled(stage == .requesting)
                .padding(.top, 20)
            case .granted:
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(kidGreen)
                    Text("Access granted!")
                        .onboardingV2TitleL()
                    OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                }
            case .denied(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(OnboardingV2Theme.Palette.tertiary)
                    Text("Access not granted")
                        .onboardingV2TitleL()
                    Text(message)
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)
                    // Not an actual retry of AuthorizationCenter — Screen
                    // Time authorization reliably fails on the Simulator
                    // (and can fail for other reasons on-device too), which
                    // would otherwise strand this prototype's onboarding on
                    // a real system dialog it can't get past. Matches every
                    // other "backend" call in this flow (pairing, sign-in):
                    // mocked to just succeed rather than gating progress on
                    // something this standalone frontend can't fulfill.
                    OnboardingV2PrimaryButton("Try Again", systemImage: "arrow.clockwise", role: .child) {
                        stage = .granted
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(OnboardingV2Theme.Palette.surfaceLowest)
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: -10)
        )
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
                    NotificationsLottieView(size: 190)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Text("\u{201C}Evlin\u{201D} Would Like to\nSend You Notifications")
                            .onboardingV2TitleL()
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                        OnboardingV2PrimaryButton("Allow", role: .child) {
                            Task { await requestThenAdvance() }
                        }
                        .disabled(requesting)
                        .padding(.top, 20)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(OnboardingV2Theme.Palette.surfaceLowest)
                            .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: -10)
                    )
                }
            },
            footer: {            }
        )
    }

    @MainActor
    private func requestThenAdvance() async {
        requesting = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        requesting = false
        onContinue()
    }
}

// MARK: - 12 · Choose what to lock

struct ChildLockableHubStep: View {
    // Owned by OnboardingV2Coordinator, not local @State — so backing up to
    // an earlier step and returning here doesn't reset an already-made
    // selection back to empty.
    @Binding var selection: FamilyActivitySelection
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

    private var totalSelected: Int {
        selection.applicationTokens.count
        + selection.categoryTokens.count
        + selection.webDomainTokens.count
    }

    private var canContinue: Bool { totalSelected > 0 || pickerOpenedOnce }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "4 · Lockable",
            stepIndex: 10,
            stepTotal: childTotal,
            title: "",
            subtitle: nil,
            onBack: onBack,
            content: {
                VStack(spacing: 16) {
                    Image(systemName: "lock.app.dashed")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(kidGreen)
                        .frame(width: 72, height: 72)
                        .background(
                            Circle().fill(OnboardingV2Theme.Palette.secondaryContainer)
                        )

                    Text("Choose Apps to Lock")
                        .onboardingV2TitleL()
                        .multilineTextAlignment(.center)
                    Text("Pick which apps your parent can lock and unlock from their phone.")
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)

                    // Selection summary
                    OnboardingV2Card {
                        if totalSelected == 0 {
                            HStack(spacing: 10) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(OnboardingV2Theme.Palette.outline)
                                Text("Tap the button below to pick apps")
                                    .onboardingV2Body()
                            }
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(kidGreen)
                                Text("\(totalSelected) item\(totalSelected == 1 ? "" : "s") selected")
                                    .font(Evlin.Typography.font(14, weight: .semibold))
                                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                                Spacer()
                                Button("Change") { showPicker = true; pickerOpenedOnce = true }
                                    .font(OnboardingV2Theme.Typography.bodyXS)
                                    .foregroundStyle(kidGreen)
                            }
                        }
                    }

                    if totalSelected == 0 {
                        OnboardingV2PrimaryButton("Choose Apps & Categories", role: .child) {
                            showPicker = true
                            pickerOpenedOnce = true
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
        .familyActivityPicker(
            headerText: "Select apps your parent can manage",
            footerText: "You can change these later.",
            isPresented: $showPicker,
            selection: $selection
        )
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

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "5 · Safety",
            stepIndex: 10,
            stepTotal: childTotal,
            title: "Do you use Family Sharing?",
            subtitle: "If your child is part of your Apple Family Sharing group, Screen Time changes already need your approval — you can skip setting a PIN in this app.",
            onBack: onBack,
            content: { EmptyView() },
            footer: {
                VStack(spacing: 10) {
                    OnboardingV2PrimaryButton("Yes, we use Family Sharing", role: .child, action: onYes)
                    OnboardingV2SecondaryButton("No, set up without it", action: onNo)
                }
            }
        )
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

            Circle()
                .fill(OnboardingV2Theme.Palette.secondaryContainer)
                .frame(width: isRegular ? 84 : 64, height: isRegular ? 84 : 64)
                .overlay(
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: isRegular ? 36 : 28, weight: .bold))
                        .foregroundStyle(kidGreen)
                )

            VStack(spacing: Spacing.lg) {
                Text("All set!").onboardingV2TitleXL()
                Text("Waiting for commands from your parent's Evlin.")
                    .onboardingV2Body()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            if !isRegular { Spacer() }

            OnboardingV2PrimaryButton("Enter Evlin", role: .child, action: onEnter)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, isRegular ? Spacing.section : 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: isRegular ? OnboardingV2Theme.Metrics.iPadCenteredMaxWidth : .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnboardingV2Theme.Palette.surface)
    }
}
