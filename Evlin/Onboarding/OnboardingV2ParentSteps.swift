import SwiftUI
import AuthenticationServices
import UserNotifications

class OAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    /// The refresh token from the last Google sign-in redirect (the callback
    /// runs off the main actor, so it's handed over through this static).
    nonisolated(unsafe) static var lastRefreshToken: String?

    func signInWithGoogle() async throws -> String {
        let supabaseURL = "https://czvuqumlmuarcltgsxag.supabase.co"
        let redirect = "evlin://auth-callback"
        let urlString = "\(supabaseURL)/auth/v1/authorize?provider=google&redirect_to=\(redirect)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "evlin") { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }
                
                let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                let fragment = components?.fragment ?? ""
                let dummyURL = URL(string: "http://dummy?\(fragment)")
                let fragmentComponents = URLComponents(url: dummyURL ?? URL(string: "http://dummy")!, resolvingAgainstBaseURL: false)
                
                OAuthManager.lastRefreshToken = fragmentComponents?.queryItems?.first(where: { $0.name == "refresh_token" })?.value
                if let token = fragmentComponents?.queryItems?.first(where: { $0.name == "access_token" })?.value {
                    continuation.resume(returning: token)
                } else if let token = components?.queryItems?.first(where: { $0.name == "access_token" })?.value {
                    continuation.resume(returning: token)
                } else {
                    let errorDesc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value ?? "No access token found in URL"
                    let err = NSError(domain: "OAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Auth failed: \(errorDesc) | URL: \(callbackURL.absoluteString)"])
                    continuation.resume(throwing: err)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}

import UIKit
import FamilyControls

// Onboarding v2 — PARENT-side screens, ported from the real app's
// Parent/V2/ParentV2PlaceholderSteps.swift + ParentBetaAgreementStep.swift +
// ParentCoParentRecoverySteps.swift. Used to have no backend at all, so
// every screen just flipped local @State after a short `Task.sleep` — sign
// in, pairing, notifications, and "waiting for the kid" now call the real
// APIClient (see submitEmailAuth/checkBackendAndProceed and
// ParentScanCodeStep below). What's still a timed stand-in rather than a
// real check is called out at each site instead of blanket-claimed here.
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
    let onSignedIn: (Bool) -> Void
    var onBack: (() -> Void)? = nil

    private enum Phase { case providers, emailAddress, password }
    private enum AuthMode { case signUp, signIn }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var phase: Phase = .providers
    @State private var authMode: AuthMode = .signUp
    @State private var email = ""
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var password = ""
    @State private var busy = false
    @State private var providersError: String?

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
            
            if let providersError {
                Text(providersError)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.error)
                    .multilineTextAlignment(.center)
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

            Button(authMode == .signUp ? "Already have an account? Sign In" : "New here? Create an account") {
                authMode = authMode == .signUp ? .signIn : .signUp
            }
            .font(OnboardingV2Theme.Typography.bodyStrong(false))
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .padding(.top, Spacing.md)
        }
    }

    // MARK: - Phase 3: password

    private var passwordContent: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                Text(email)
                    .font(OnboardingV2Theme.Typography.bodyStrong(false))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                Spacer()
                Button("Edit") { phase = .emailAddress }
                    .font(OnboardingV2Theme.Typography.bodyStrong(false))
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

            Button(authMode == .signUp ? "Already have an account? Sign In" : "New here? Create an account") {
                authMode = authMode == .signUp ? .signIn : .signUp
            }
            .font(OnboardingV2Theme.Typography.bodyStrong(false))
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .padding(.top, Spacing.md)
        }
    }

    private func submitEmailAuth() async {
        busy = true
        let success: Bool

        var actualError: String? = nil
        do {
            if authMode == .signUp {
                success = try await APIClient.shared.register(email: email, password: password)
            } else {
                success = try await APIClient.shared.login(email: email, password: password)
            }
        } catch {
            success = false
            actualError = error.apiUserMessage
        }

        busy = false
        
        if success {
            if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let local = email.split(separator: "@").first.map(String.init) ?? "Morgan"
                parentName = local.capitalized
            }
            if let error = await checkBackendAndProceed() { passwordError = error }
        } else {
            passwordError = actualError ?? (authMode == .signUp ? "Failed to create account." : "Incorrect email or password.")
        }
    }

    /// A returning parent with an already-paired kid used to get silently
    /// routed back through full onboarding (including a fresh pairing scan)
    /// whenever this fetch failed — the error was only ever printed, and a
    /// throw here was indistinguishable from "this account really has no
    /// kids yet." Now a failure returns a real message instead of guessing,
    /// so the caller can show it and let the parent retry (signing in again
    /// is safe to repeat — register() already treats an existing account as
    /// a login).
    private func checkBackendAndProceed() async -> String? {
        busy = true
        do {
            let kids = try await APIClient.shared.fetchChildren()
            let hasKids = kids.contains(where: { $0.isPaired })
            busy = false
            await MainActor.run { onSignedIn(hasKids) }
            return nil
        } catch {
            busy = false
            return "Signed in, but couldn't check your account. \(error.apiUserMessage)"
        }
    }

    private func signInWithProvider() async {
        busy = true
        providersError = nil
        do {
            let manager = OAuthManager()
            let token = try await manager.signInWithGoogle()
            let success = try await APIClient.shared.verifyParent(token: token)
            if success {
                SessionManager.shared.parentRefreshToken = OAuthManager.lastRefreshToken
                if let error = await checkBackendAndProceed() { providersError = error }
            } else {
                providersError = "Failed to sync Google login with backend."
            }
        } catch let error as NSError {
            // ASWebAuthenticationSessionErrorCode.canceledLogin is error code 1
            if error.domain == ASWebAuthenticationSessionErrorDomain && error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                // User intentionally cancelled, just silently ignore it
                providersError = nil
            } else {
                providersError = error.localizedDescription
            }
        }
        busy = false
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
    @State private var errorText: String?

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

                        if let errorText {
                            Text(errorText)
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .foregroundStyle(OnboardingV2Theme.Palette.error)
                        }

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
        errorText = nil
        do {
            try await ParentProfile.shared.saveNow(name)
            withAnimation { saved = true }
        } catch {
            errorText = "Couldn't save your name. \(error.apiUserMessage)"
        }
        busy = false
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

// MARK: - 6 · Scan or type the code shown on the kid's device

struct ParentScanCodeStep: View {
    /// Called with the child's name once the code has been accepted.
    let onPaired: (String) -> Void
    var onBack: (() -> Void)? = nil

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
                        Text("Connect Your Child's Device")
                            .onboardingV2TitleL()
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text("Open Evlin on your child's device and choose Child. Scan the QR code it shows, or type the 6-digit code.")
                            .onboardingV2Body()
                            .multilineTextAlignment(.center)
                    }
                    PairCodeEntry(accent: OnboardingV2Theme.Palette.primary) { code in
                        let child = try await APIClient.shared.claimPairing(code: code)
                        SessionManager.shared.activeChildId = child.id
                        // RootView uses this as the child's name until the first sync lands.
                        NotificationCenter.default.post(name: NSNotification.Name("EvlinKidPaired"), object: child.name)
                        onPaired(child.name)
                    }
                }
            },
            footer: { }
        )
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
    let onReady: () -> Void
    var onBack: (() -> Void)? = nil

    private var name: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
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
                // Used to show a two-item checklist ("Allowed Screen Time" /
                // "Picked an app Evlin can lock") that flipped to checked on
                // fixed timers regardless of what the kid's device actually
                // did — there's no backend field yet reporting either of
                // those in real time from the kid's own onboarding chain, so
                // faking specific checkmarks (and a hardcoded "TikTok" as
                // the "first blocked app") just lied with false precision.
                // \(name) has already really paired (that's why this step
                // is reachable at all — see ParentScanCodeStep); the rest of
                // their own setup happens on their own device's chain, which
                // asks for Screen Time for real.
                VStack(spacing: Spacing.lg) {
                    OnboardingV2WaitingSpinner(name: name, subtitle: "Finishing setup…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {            }
        )
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            onReady()
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
// — a custom "pre-permission" screen styled like the system dialog; tapping
// Allow now triggers the real UNUserNotificationCenter prompt on top of it,
// same as ChildAllowNotificationsStep.)

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
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        requesting = false
        onContinue()
    }
}
