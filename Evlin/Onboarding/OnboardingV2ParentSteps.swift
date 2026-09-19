import SwiftUI
import UIKit
import FamilyControls

// Onboarding v2 — PARENT-side screens, ported from the real app's
// Parent/V2/ParentV2PlaceholderSteps.swift + ParentBetaAgreementStep.swift +
// ParentCoParentRecoverySteps.swift. This prototype has no backend, so every
// screen that used to call AuthService / APIClient now just flips local
// @State after a short `Task.sleep` (kept only where the source showed a
// loading state worth preserving for feel — sign-in, pairing, the first-block
// test, "welcome back").
//
// Step counter convention kept identical to the source for fidelity: the
// parent v2 chain is numbered as a 12-step flow (1 welcome · 2 modeSelect are
// handled by RootView's ModePickerView in this prototype, so the chain here
// starts at 3 · sign in).

// Dots reflect only the screens actually shown inside this coordinator —
// the "1 welcome · 2 modeSelect" screens mentioned above live in RootView
// and were previously baked into these numbers, which made the very first
// screen a user swipes through start on the 3rd dot with no 1st/2nd dot
// ever shown (read as "it skipped two pages"). Renumbered to start at 0.
private let parentTotal = 8

// MARK: - 3 · Sign in

struct ParentSignInStep: View {
    @Binding var parentName: String
    let onSignedIn: () -> Void
    var onBack: (() -> Void)? = nil

    private enum Phase { case providers, emailAddress, password, confirmEmail }
    private enum AuthMode { case signUp, signIn }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var phase: Phase = .providers
    @State private var authMode: AuthMode = .signUp
    @State private var email = ""
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var password = ""
    @State private var busy = false
    @State private var confirmCode = ""
    @State private var codeError: String?
    @State private var resending = false
    @State private var justResent = false

    private var isValidEmail: Bool {
        guard let at = email.firstIndex(of: "@") else { return false }
        let domain = email[email.index(after: at)...]
        return at != email.startIndex && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
    private var canSubmitPassword: Bool { password.count >= 6 && !busy }

    private var title: String { "" }
    private var subtitle: String { "" }

    // Back inside this one step is phase-dependent (email → providers,
    // password → email) rather than the fixed step-to-step `onBack` every
    // other screen uses — the top icon button now drives both cases through
    // this single computed action instead of the old per-phase back links.
    private var backAction: (() -> Void)? {
        switch phase {
        case .providers: return onBack
        case .emailAddress: return { phase = .providers }
        case .password: return { phase = .emailAddress }
        case .confirmEmail: return nil
        }
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: parentTotal,
            title: title,
            subtitle: subtitle,
            dotsCount: parentTotal,
            dotsCurrent: 0,
            onBack: backAction,
            content: {
                switch phase {
                case .providers: providersContent
                case .emailAddress: emailAddressContent
                case .password: passwordContent
                case .confirmEmail: confirmEmailContent
                }
            },
            footer: { EmptyView() }
        )
    }

    // MARK: - Phase 1: provider choice

    private var providersContent: some View {
        VStack(spacing: 11) {
            OnboardingV2PrimaryButton(
                "Continue with Email",
                systemImage: "envelope.fill",
                role: .parent,
                action: { phase = .emailAddress }
            )
            .disabled(busy)

            OnboardingV2PrimaryButton(
                "Continue with Apple",
                systemImage: "apple.logo",
                fill: .black,
                action: { Task { await signInWithProvider() } }
            )
            .disabled(busy)

            Button(action: { Task { await signInWithProvider() } }) {
                HStack(spacing: 8) {
                    Text("G").font(.system(size: 15, weight: .bold))
                    Text("Continue with Google")
                }
                .font(OnboardingV2Theme.Typography.cta(hSizeClass == .regular))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, hSizeClass == .regular ? OnboardingV2Theme.Metrics.ctaPaddingVertical + 14 : OnboardingV2Theme.Metrics.ctaPaddingVertical)
                .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                     style: .continuous)
                        .fill(OnboardingV2Theme.Palette.surfaceLowest)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                     style: .continuous)
                        .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if busy {
                HStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").onboardingV2BodyXS()
                }
                .padding(.top, Spacing.sm)
            }
        }
    }

    // MARK: - Phase 2: email address

    private var emailAddressContent: some View {
        VStack(spacing: 11) {
            OnboardingV2EditableField(label: "EMAIL", text: $email, placeholder: "you@example.com", keyboardType: .emailAddress)
                .onChange(of: email) { _, _ in emailError = nil }

            if let emailError {
                Text(emailError)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            OnboardingV2PrimaryButton("Continue", role: .parent) {
                if isValidEmail {
                    phase = .password
                } else {
                    emailError = "Enter a valid email address."
                }
            }
            .padding(.top, Spacing.xs)

            Button(authMode == .signUp ? "Already have an account? Sign in" : "New here? Create an account") {
                authMode = authMode == .signUp ? .signIn : .signUp
            }
            .font(OnboardingV2Theme.Typography.bodyXS)
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .padding(.top, Spacing.xs)
        }
    }

    // MARK: - Phase 3: password

    private var passwordContent: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                Text(email)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                Spacer()
                Button("Edit") { phase = .emailAddress }
                    .font(OnboardingV2Theme.Typography.bodyXS)
                    .foregroundStyle(OnboardingV2Theme.Palette.primary)
            }

            OnboardingV2EditableField(
                label: authMode == .signUp ? "CREATE PASSWORD" : "PASSWORD",
                text: $password,
                placeholder: "At least 6 characters",
                isSecure: true
            )
            .onChange(of: password) { _, _ in passwordError = nil }

            if let passwordError {
                Text(passwordError)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            OnboardingV2PrimaryButton(
                busy ? (authMode == .signUp ? "Creating account…" : "Signing in…")
                     : (authMode == .signUp ? "Create account" : "Sign in"),
                role: .parent,
                action: { Task { await submitEmailAuth() } }
            )
            .disabled(!canSubmitPassword)
            .padding(.top, Spacing.xs)
        }
    }

    // MARK: - Phase 4: confirm email (sign-up only)

    private var confirmEmailContent: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle().fill(OnboardingV2Theme.Palette.primaryContainer).frame(width: 84, height: 84)
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(OnboardingV2Theme.Palette.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Spacing.sm)

            OnboardingV2CodeField(code: $confirmCode)
                .onChange(of: confirmCode) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue {
                        confirmCode = digits
                    }
                    codeError = nil
                    if digits.count == 6 && !busy { Task { await finishSignUp() } }
                }

            if busy {
                HStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Verifying…").onboardingV2BodyXS()
                }
            }
            if let codeError {
                Text(codeError).onboardingV2BodyXS().foregroundStyle(OnboardingV2Theme.Palette.error)
            }

            Button(justResent ? "Code sent" : "Resend code") {
                Task { await resendEmail() }
            }
            .font(OnboardingV2Theme.Typography.bodyXS)
            .foregroundStyle(justResent ? OnboardingV2Theme.Palette.secondary : OnboardingV2Theme.Palette.primary)
            .disabled(resending || justResent)

            Button("Wrong email?") { phase = .emailAddress }
                .font(OnboardingV2Theme.Typography.bodyXS)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
        }
    }

    
    private func resendEmail() async {
        resending = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        resending = false
        justResent = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        justResent = false
    }

    
    private func finishSignUp() async {
        busy = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        busy = false
        // Mocked, matching this app's other "any code succeeds" flows — no
        // backend to actually issue/check a code against.
        if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let local = email.split(separator: "@").first.map(String.init) ?? "Morgan"
            parentName = local.capitalized
        }
        onSignedIn()
    }

    
    
    private func submitEmailAuth() async {
        busy = true
        let success: Bool
        
        do {
            if authMode == .signUp {
                success = try await APIClient.shared.register(email: email, password: password)
            } else {
                success = try await APIClient.shared.login(email: email, password: password)
            }
        } catch {
            success = false
        }
        
        busy = false
        
        if success {
            if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let local = email.split(separator: "@").first.map(String.init) ?? "Morgan"
                parentName = local.capitalized
            }
            // Skip the mocked confirm email phase entirely now that backend auth is wired up
            onSignedIn()
        } else {
            passwordError = authMode == .signUp ? "Failed to create account. Email might be in use or password is too weak." : "Incorrect email or password."
        }
    }

    
    private func signInWithProvider() async {
        busy = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        busy = false
        if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parentName = "Morgan"
        }
        onSignedIn()
    }
}

// MARK: - 4 · Your profile

struct ParentProfileStep: View {
    @Binding var name: String
    @Binding var pickedAvatar: UIImage?
    let onSaved: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var genderIndex = 0
    @State private var ageText = ""
    @State private var saved = false
    @State private var busy = false

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 1,
            onBack: onBack,
            content: {
                if saved {
                    VStack(spacing: Spacing.lg) {
                        OnboardingV2SuccessCheck(role: .parent, size: 54)
                        Text("Profile saved").onboardingV2BodyStrong()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.section)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        OnboardingV2PhotoAvatarPicker(name: name, pickedImage: $pickedAvatar)
                            .frame(maxWidth: .infinity)

                        OnboardingV2EditableField(label: "NAME", text: $name)

                        OnboardingV2EditableField(label: "AGE", text: $ageText, placeholder: "e.g. 35", keyboardType: .numberPad)
                            .onChange(of: ageText) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(2))
                                if digits != newValue {
                                    ageText = digits
                                }
                            }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("GENDER").onboardingV2FieldLabel()
                            OnboardingV2Segmented(options: ["Female", "Male", "Other"],
                                                  selectedIndex: $genderIndex)
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(busy ? "Saving…" : "Continue", role: .parent) {
                    if saved { onSaved() } else { Task { await save() } }
                }
                .disabled(busy)            }
        )
    }

    
    private func save() async {
        busy = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        busy = false
        withAnimation { saved = true }
    }
}

// MARK: - Beta agreement — two checkbox rows (Terms of Use, Privacy Policy)

struct ParentBetaAgreementStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var agreedTerms = false
    @State private var agreedPrivacy = false
    @State private var showTermsSheet = false
    @State private var showPrivacySheet = false

    private var allAgreed: Bool { agreedTerms && agreedPrivacy }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: "Beta agreement",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 1,
            onBack: onBack,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ContractSignLottieView(size: 160)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, Spacing.md)
                    AgreementCheckRow(
                        label: "I agree and accept the",
                        linkText: "Terms of Use",
                        checked: $agreedTerms,
                        onTapLink: { showTermsSheet = true }
                    )
                    AgreementCheckRow(
                        label: "I agree and accept the",
                        linkText: "Privacy Policy",
                        checked: $agreedPrivacy,
                        onTapLink: { showPrivacySheet = true }
                    )
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .parent, action: onContinue)
                    .disabled(!allAgreed)
            }
        )
        .sheet(isPresented: $showTermsSheet) {
            AgreementDocSheet(title: "Terms of Use", sections: BetaAgreementContent.termsSections)
        }
        .sheet(isPresented: $showPrivacySheet) {
            AgreementDocSheet(title: "Privacy Policy", sections: BetaAgreementContent.privacySections)
        }
    }
}

// One tappable row: checkbox + "I agree and accept the [Doc Name]" — tapping
// the row toggles the checkbox, tapping the doc name opens its full text
// instead, matching how these two actions read as separate affordances.
struct AgreementCheckRow: View {
    let label: String
    let linkText: String
    @Binding var checked: Bool
    let onTapLink: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { checked.toggle() }
        } label: {
            // Bigger across the board — checkbox, row height, and text were
            // all sized like a fine-print footnote for something that's
            // actually the one required approval gating the whole flow.
            HStack(spacing: Spacing.lg) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 28))
                    .foregroundStyle(checked ? OnboardingV2Theme.Palette.secondary
                                              : OnboardingV2Theme.Palette.outline)

                (Text("\(label) ")
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                 + Text(linkText)
                    .foregroundStyle(OnboardingV2Theme.Palette.secondary)
                    .underline())
                    .font(Evlin.Typography.font(15, weight: .medium))
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.lg)
            .frame(minHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(checked ? OnboardingV2Theme.Palette.secondary.opacity(0.06)
                                  : OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(checked ? OnboardingV2Theme.Palette.secondary.opacity(0.4)
                                           : OnboardingV2Theme.Palette.outlineVariant,
                                  lineWidth: checked ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            // A second, smaller tap target over just the link text so opening
            // the document doesn't also toggle the checkbox underneath it.
            // Sized to match the row's bigger text/height above.
            Button(action: onTapLink) { Color.clear }
                .frame(width: 120, height: 68)
                .padding(.trailing, Spacing.lg)
        }
    }
}

struct AgreementDocSheet: View {
    let title: String
    let sections: [BetaAgreementContent.Section]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(BetaAgreementContent.version)
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    ForEach(sections, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(section.heading).onboardingV2BodyStrong()
                            Text(section.body)
                                .onboardingV2BodyXS()
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}

enum BetaAgreementContent {
    static let header = "EVLIN INC. — BETA PARTICIPATION AGREEMENT"
    static let version = "v2.0 · July 2026"

    struct Section {
        let heading: String
        let body: String
    }

    static let sections: [Section] = [
        Section(
            heading: "1. Nature of the Beta Program",
            body: """
            The Services are pre-release, under active development, and provided for testing and evaluation. Features may be incomplete, may change or be removed without notice. Participation is free of charge; you are not entitled to compensation for participation or feedback.
            """
        ),
        Section(
            heading: "2. Enforcement limitations — read carefully",
            body: """
            Device locking, screen-time enforcement, and content controls depend on operating-system frameworks outside Evlin's control. Locks and limits may apply late, apply incorrectly, or fail entirely. Evlin is a convenience tool, not a safety device, and is not a substitute for adult supervision.
            """
        ),
        Section(
            heading: "3. Eligibility",
            body: """
            You represent that you are at least 18 years old, the parent or legal guardian of each enrolled child, and own (or have authority over) each enrolled device.
            """
        ),
        Section(
            heading: "4. Children's data",
            body: """
            Evlin will not serve advertising to your child, will not sell or share child data, and will not use child data to train AI models. You may review, export, or delete your child's data at any time.
            """
        ),
        Section(
            heading: "5. Feedback",
            body: """
            You may provide suggestions and bug reports. Evlin may use this feedback without restriction or attribution.
            """
        ),
        Section(
            heading: "6. Term and termination",
            body: """
            This agreement runs until the end of the Beta Program, or until either party terminates it for any reason, at any time.
            """
        ),
    ]

    /// Sections shown in the "Terms of Use" sheet.
    static let termsSections: [Section] = [sections[0], sections[1], sections[2], sections[4], sections[5]]
    /// Sections shown in the "Privacy Policy" sheet.
    static let privacySections: [Section] = [sections[3]]
}

// MARK: - 6 · Show Code to Pair

struct ParentShowCodeStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var code = "------"
    @State private var expiresAt = ""
    @State private var busy = true
    @State private var errorText: String?

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 2,
            onBack: onBack,
            content: {
                VStack(spacing: Spacing.lg) {
                    VStack(spacing: 8) {
                        Text("Pair Your Child's Device")
                            .onboardingV2TitleL()
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text("Enter this 6-digit code on your child's iPad to link it to your account.")
                            .onboardingV2Body()
                            .multilineTextAlignment(.center)
                    }

                    if busy {
                        ProgressView("Generating secure code...")
                            .padding(.vertical, Spacing.xl)
                    } else {
                        Text(code)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                            .padding(.vertical, Spacing.xl)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius, style: .continuous)
                                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
                            )
                        
                        if !expiresAt.isEmpty {
                            Text("Expires at \(expiresAt)")
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.center)
                    }

                    OnboardingV2PrimaryButton("Continue", role: .parent) {
                        onContinue()
                    }
                    .disabled(busy)
                }
            },
            footer: { }
        )
        .task {
            await fetchCode()
        }
    }

    
    private func fetchCode() async {
        busy = true
        errorText = nil
        do {
            // Using a mock child UUID for the UI prototype until user profile creation is fully wired
            let result = try await APIClient.shared.generatePairingCode(childId: "123e4567-e89b-12d3-a456-426614174000")
            code = result.code
            expiresAt = result.expiresAt
        } catch {
            errorText = "Failed to generate pairing code. Please try again."
        }
        busy = false
    }
}

// MARK: - 7 · Connected (parent)

struct ParentConnectedStep: View {
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    private var name: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "3 · Pair",
            stepIndex: 7,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 3,
            onBack: onBack,
            content: {
                VStack(spacing: Spacing.xl) {
                    OnboardingV2SuccessCheck(role: .parent, size: 62)
                    Text("Connected to \(name)").onboardingV2TitleL()
                    Text("You're paired! Now let's set up permissions and pick which apps to manage.")
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .parent, action: onContinue)
            }
        )
    }
}

// MARK: - 10 · Waiting for kid

struct ParentWaitingForKidStep: View {
    var kidName: String = ""
    /// Mocked: auto-fires after a short simulated wait, carrying a fake
    /// first-block app name.
    let onReady: (String) -> Void
    var onBack: (() -> Void)? = nil

    @State private var screenTimeGranted = false
    @State private var pickedApp = false

    private var name: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
    }

    private var waitingSubtitle: String {
        if !screenTimeGranted { return "Waiting for \(name) to allow Screen Time…" }
        if !pickedApp { return "Waiting for \(name) to pick an app Evlin can lock…" }
        return "Ready!"
    }

    private func waitRow(_ done: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? OnboardingV2Theme.Palette.secondary
                                      : OnboardingV2Theme.Palette.outline)
            Text(text).onboardingV2BodyXS()
        }
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "4 · Finish",
            stepIndex: 10,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 6,
            onBack: onBack,
            content: {
                VStack(spacing: Spacing.lg) {
                    OnboardingV2WaitingSpinner(name: name, subtitle: waitingSubtitle)
                    VStack(alignment: .leading, spacing: 8) {
                        waitRow(screenTimeGranted, "Allowed Screen Time")
                        waitRow(pickedApp, "Picked an app Evlin can lock")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {            }
        )
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            screenTimeGranted = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            pickedApp = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            onReady("TikTok")
        }
    }
}

// MARK: - 9 · Tamper passcode (also reused on the KID chain)

struct ParentSetPasscodeV2Step: View {
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var role: OnboardingV2Role = .parent
    var phase: String = "5 · Parent finish"
    var stepIndex: Int = 9
    var dotsCurrent: Int = 6
    var total: Int = parentTotal

    private var kid: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    private var subtitleText: String {
        role == .child
            ? "Set a Screen Time passcode on this phone — it stops Evlin from being turned off."
            : "Set a Screen Time passcode \(kid) doesn't know — it stops them turning Evlin off."
    }

    // "I've set it" doesn't jump straight to onContinue — a parent tapping
    // through a numbered checklist is exactly the kind of place a fat-finger
    // "done" happens before the real Settings trip does. One quick yes/no
    // catches that without making them re-read the steps.
    @State private var showConfirm = false

    var body: some View {
        OnboardingV2ScreenContainer(
            role: role,
            phase: phase,
            stepIndex: stepIndex,
            stepTotal: total,
            title: "",
            subtitle: nil,
            dotsCount: total,
            dotsCurrent: dotsCurrent,
            onBack: onBack,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ZStack(alignment: .top) {
                        ScreenTimePINVideoView()
                        // This lock also blocks deleting the Evlin app itself
                        // (same Screen Time passcode gates both) — easy to
                        // miss since the checklist below only talks about
                        // the toggle, not the app disappearing entirely.
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Also stops \(kid) from deleting Evlin")
                                .font(Evlin.Typography.font(11.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(.top, 10)
                    }
                    OnboardingV2NumberedStep(number: 1, text: "Open Settings → Screen Time")
                    OnboardingV2NumberedStep(number: 2, text: "Tap \u{201C}Lock Screen Time Settings\u{201D}")
                    OnboardingV2NumberedStep(number: 3, text: "Pick a 4-digit code \(kid) won't guess")
                }
            },
            footer: {
                OnboardingV2SecondaryButton("Open Screen Time settings", action: openScreenTimeSettings)
                OnboardingV2PrimaryButton("I've set it", role: role) { showConfirm = true }
            }
        )
        .overlay {
            if showConfirm {
                PasscodeConfirmCard(
                    kidName: kid,
                    onConfirm: { showConfirm = false; onContinue() },
                    onNotYet: { showConfirm = false }
                )
            }
        }
        .animation(.easeOut(duration: 0.2), value: showConfirm)
    }

    // There's no public API for a third-party app to deep-link straight into
    // a specific Settings pane like Screen Time — `prefs:` URL schemes have
    // been blocked for non-system apps since iOS 8, and this never opens on
    // a real device or in Simulator, so it's not worth attempting. The only
    // thing UIApplication actually supports is opening the app's own
    // Settings page — the parent still has to tap into Screen Time from
    // there themselves.
    private func openScreenTimeSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// A single yes/no check, not a form — the point is to catch an accidental
// tap without turning "I've set it" into its own multi-step interruption.
private struct PasscodeConfirmCard: View {
    var kidName: String
    var onConfirm: () -> Void
    var onNotYet: () -> Void
    // A full-screen .overlay, not routed through OnboardingV2ScreenContainer
    // (it sits on top of that container, at the whole-screen scope) — so it
    // never picked up that container's iPhone-width cap and just stretched
    // its card across the full iPad width via a bare horizontal padding.
    // Same fix, applied directly here.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onNotYet)

            VStack(alignment: .leading, spacing: 14) {
                Text("Did you set the Screen Time passcode?")
                    .font(Evlin.Typography.font(17, weight: .heavy))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Text("Without it set on the device, \(kidName) could bypass everything Evlin does.")
                    .font(Evlin.Typography.font(13.5, weight: .regular))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    OnboardingV2PrimaryButton("Yes, I set it", role: .parent, action: onConfirm)
                    OnboardingV2SecondaryButton("Not yet", action: onNotYet)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
            .padding(.horizontal, 24)
            .frame(maxWidth: isRegular ? OnboardingV2Theme.Metrics.iPadCenteredMaxWidth : .infinity)
        }
        .transition(.opacity)
    }
}

// MARK: - Final · parent onboarding done

struct ParentOnboardingDoneStep: View {
    let onEnter: () -> Void
    // Doesn't route through OnboardingV2ScreenContainer (nothing here needs
    // its phase tag/step counter/back button), so it needs its own iPad
    // cap — without one this full-bleed splash stretched its CTA edge to
    // edge across the iPad's width instead of reading as one iPhone-shaped
    // screen. See OnboardingV2ScreenContainer's own comment for why this
    // matches iPhone rather than scaling up like the kid tablet screens do.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    var body: some View {
        VStack(spacing: Spacing.section) {
            // On iPhone, the two flexible Spacers push the icon/title up
            // and the button down within a short screen. On iPad's much
            // taller canvas they'd absorb all of it instead, stranding
            // everything at the far top/bottom with the actual content
            // lost in an empty middle — so on regular width this drops
            // them and lets the outer frame's centered alignment (below)
            // position the whole compact block in the middle of the
            // screen instead.
            if !isRegular { Spacer() }

            Circle()
                .fill(OnboardingV2Theme.Palette.primary)
                .frame(width: isRegular ? 84 : 64, height: isRegular ? 84 : 64)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: isRegular ? 36 : 28, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                )

            Text("Your child is protected.")
                .onboardingV2TitleXL()
                .multilineTextAlignment(.center)

            if !isRegular { Spacer() }

            OnboardingV2PrimaryButton("Enter Evlin", role: .parent, action: onEnter)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, isRegular ? Spacing.section : 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: isRegular ? OnboardingV2Theme.Metrics.iPadCenteredMaxWidth : .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnboardingV2Theme.Palette.surface)
    }
}

// MARK: - Parent notifications ask (ported from evlin-next's parent/notifications
// — mirrors ChildAllowNotificationsStep's mocked iOS-permission-sheet pattern.)

struct ParentNotificationsAskStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var requesting = false

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "3 · Permissions",
            stepIndex: 9,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 4,
            onBack: onBack,
            content: {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NotificationsLottieView(size: 200)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Text("\u{201C}Evlin\u{201D} Would Like to\nSend You Notifications")
                            .onboardingV2TitleL()
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                        OnboardingV2PrimaryButton("Allow", role: .parent) {
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
            footer: {
            }
        )
    }

    
    private func requestThenAdvance() async {
        requesting = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        requesting = false
        onContinue()
    }
}

