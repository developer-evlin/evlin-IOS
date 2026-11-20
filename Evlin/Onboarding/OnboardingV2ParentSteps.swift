import SwiftUI
import AuthenticationServices
import CryptoKit
import UserNotifications

/// Shows Apple's native Sign in with Apple sheet. The request carries the
/// SHA-256 of a fresh random nonce; the raw nonce goes to our server, which
/// checks Apple's token carries its hash, so a token can't be replayed from
/// another sign-in.
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                    ASAuthorizationControllerPresentationContextProviding {
    struct Result {
        let identityToken: String
        let authorizationCode: String?
        let rawNonce: String
        let fullName: String?
    }

    private var continuation: CheckedContinuation<Result, Error>?
    private var rawNonce = ""
    /// Holds this object alive while the sheet is up; the controller's
    /// delegate reference is weak.
    private var retainedSelf: AppleSignInCoordinator?

    @MainActor
    func signIn() async throws -> Result {
        rawNonce = Self.randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(rawNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        retainedSelf = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { retainedSelf = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: NSError(domain: "AppleSignIn", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Apple didn't return a sign-in token. Try again."]))
            continuation = nil
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential.fullName.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
        }
        continuation?.resume(returning: Result(identityToken: token, authorizationCode: code,
                                               rawNonce: rawNonce, fullName: name))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { retainedSelf = nil }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure random bytes for the Apple nonce")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Error {
    /// The server's own words for a sign-in failure ("That code is wrong or
    /// has expired", "Wait 40 seconds…"), which the generic `apiUserMessage`
    /// would turn into "session expired" for a 401 or a raw status for the rest.
    var signInMessage: String {
        if let f = self as? APIFailure, (400..<500).contains(f.status) {
            if f.status == 422 { return "Check the email and password. Passwords need at least 8 characters." }
            if let detail = f.detail, !detail.isEmpty {
                return detail == "Invalid login credentials" ? "Incorrect email or password." : detail
            }
        }
        return apiUserMessage
    }
}

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
        #if EVLIN_DEMO
        let supabaseURL = "https://demo.invalid"
        #else
        let supabaseURL = "https://czvuqumlmuarcltgsxag.supabase.co"
        #endif
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
    /// (a kid is already paired, the parent's name is known)
    let onSignedIn: (Bool, Bool) -> Void
    var onBack: (() -> Void)? = nil

    private enum Phase { case providers, emailAddress, password, code }
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
    @State private var code = ""
    @State private var codeError: String?
    @State private var resendAvailableAt = Date.distantPast

    private var isValidEmail: Bool {
        guard let at = email.firstIndex(of: "@") else { return false }
        let domain = email[email.index(after: at)...]
        return at != email.startIndex && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
    private var canSubmitPassword: Bool { password.count >= 8 && !busy }
    private var canSubmitCode: Bool { code.filter(\.isNumber).count == 6 && !busy }

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
        case .code: return { phase = .password }
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
                case .code: codeContent
                }
            },
            footer: { EmptyView() }
        )
        // Already signed in (setup was left partway): don't ask again. Go on
        // to the rest of setup, or straight home if a kid is paired already.
        .task {
            guard phase == .providers, SessionManager.shared.hasParentSession else { return }
            if let error = await checkBackendAndProceed() { providersError = error }
        }
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
                action: { Task { await signInWithApple() } }
            )
            .disabled(busy)

            Button(action: { Task { await signInWithProvider() } }) {
                // Google's own four-colour G, as its sign-in buttons show it
                // (2026-11-16, the user's call: the plain grey "G" was hard
                // to see), on a firmer edge so the button reads on the page.
                HStack(spacing: hSizeClass == .regular ? 12 : 10) {
                    Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: hSizeClass == .regular ? 24 : 19, height: hSizeClass == .regular ? 24 : 19)
                        .accessibilityHidden(true)
                    Text("Continue with Google")
                }
                .font(OnboardingV2Theme.Typography.cta(hSizeClass == .regular))
                .foregroundStyle(Color(light: "1F1F1F", dark: "E6E8EC", warm: "E6E8EC"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                     style: .continuous)
                        .fill(OnboardingV2Theme.Palette.surfaceLowest)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                     style: .continuous)
                        .strokeBorder(Color(light: "C7C7CC", dark: "4A505A", warm: "4A505A"), lineWidth: 1)
                )
                .frame(height: hSizeClass == .regular ? OnboardingV2Theme.Metrics.ctaHeightRegular : OnboardingV2Theme.Metrics.ctaHeightCompact)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: OnboardingV2Theme.Metrics.ctaMaxWidth)
            .frame(maxWidth: .infinity)
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
            OnboardingV2EditableField(label: "Email", text: $email, placeholder: "you@example.com", keyboardType: .emailAddress)
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
                placeholder: "At least 8 characters",
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
                busy ? (authMode == .signUp ? "Sending code…" : "Signing in…")
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

    // MARK: - Phase 4: the emailed code (sign-up only)

    private var codeContent: some View {
        VStack(spacing: 11) {
            Text("We sent a 6-digit code to \(email). Enter it to finish creating your account.")
                .onboardingV2BodyXS()
                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)

            OnboardingV2EditableField(
                label: "Code",
                text: $code,
                placeholder: "123456",
                keyboardType: .numberPad,
                contentType: .oneTimeCode
            )
            .onChange(of: code) { _, new in
                codeError = nil
                let digits = String(new.filter(\.isNumber).prefix(6))
                if digits != new { code = digits }
            }

            if let codeError {
                Text(codeError)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            OnboardingV2PrimaryButton(busy ? "Checking…" : "Verify and continue", role: .parent) {
                Task { await submitCode() }
            }
            .disabled(!canSubmitCode)
            .padding(.top, Spacing.xs)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                Button(wait > 0 ? "Resend code in \(wait)s" : "Resend code") {
                    Task { await sendCode() }
                }
                .disabled(wait > 0 || busy)
                .font(OnboardingV2Theme.Typography.bodyStrong(false))
                .foregroundStyle(OnboardingV2Theme.Palette.primary)
            }
            .padding(.top, Spacing.md)
        }
    }

    private func submitEmailAuth() async {
        if authMode == .signUp {
            if await sendCode() { phase = .code }
            return
        }
        busy = true
        do {
            let success = try await APIClient.shared.login(email: email, password: password)
            busy = false
            if success {
                await finishSignIn()
            } else {
                passwordError = "Incorrect email or password."
            }
        } catch {
            busy = false
            passwordError = error.signInMessage
        }
    }

    /// Asks the server to email a code. Returns whether one went out.
    @discardableResult
    private func sendCode() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let wait = try await APIClient.shared.startSignup(email: email)
            resendAvailableAt = Date().addingTimeInterval(TimeInterval(wait))
            code = ""
            codeError = nil
            return true
        } catch {
            if let f = error as? APIFailure, f.status == 429 {
                // A code is already on its way; let them enter it.
                if phase != .code { phase = .code }
                codeError = error.signInMessage
                return false
            }
            if phase == .code { codeError = error.signInMessage } else { passwordError = error.signInMessage }
            return false
        }
    }

    private func submitCode() async {
        busy = true
        do {
            let success = try await APIClient.shared.verifySignup(email: email, password: password,
                                                                  code: code.filter(\.isNumber))
            busy = false
            if success { await finishSignIn() } else { codeError = "Couldn't finish signing up. Try again." }
        } catch {
            busy = false
            codeError = error.signInMessage
        }
    }

    private func finishSignIn() async {
        if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let local = email.split(separator: "@").first.map(String.init) ?? "Morgan"
            parentName = local.capitalized
        }
        if let error = await checkBackendAndProceed() {
            if phase == .code { codeError = error } else { passwordError = error }
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
            let name = await knownName()
            busy = false
            await MainActor.run { onSignedIn(hasKids, !name.isEmpty) }
            return nil
        } catch {
            busy = false
            return "Signed in, but couldn't check your account. \(error.apiUserMessage)"
        }
    }

    /// The parent's name without asking for it: the one already on the
    /// account (an earlier sign-in, or Apple's first one), else the one this
    /// sign-in brought (Apple's or Google's), which is then saved to the
    /// account. Empty only for an email sign-up, where onboarding asks.
    private func knownName() async -> String {
        let fromSignIn = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let me = try? await APIClient.shared.fetchMe() {
            ParentProfile.shared.load(me)
            let onAccount = (me.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !onAccount.isEmpty {
                parentName = onAccount
                return onAccount
            }
        }
        guard !fromSignIn.isEmpty else { return "" }
        try? await ParentProfile.shared.saveNow(fromSignIn)
        return fromSignIn
    }

    private func signInWithApple() async {
        busy = true
        providersError = nil
        defer { busy = false }
        do {
            let result = try await AppleSignInCoordinator().signIn()
            let success = try await APIClient.shared.signInWithApple(
                identityToken: result.identityToken, nonce: result.rawNonce,
                authorizationCode: result.authorizationCode, fullName: result.fullName)
            guard success else {
                providersError = "Couldn't finish signing in with Apple. Try again."
                return
            }
            if let name = result.fullName, !name.isEmpty,
               parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parentName = name
            }
            if let error = await checkBackendAndProceed() { providersError = error }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            providersError = nil
        } catch {
            providersError = error.signInMessage
        }
    }

    private func signInWithProvider() async {
        busy = true
        providersError = nil
        do {
            let manager = OAuthManager()
            let token = try await manager.signInWithGoogle()
            // Without a refresh token the session would end with the access
            // token, about an hour later. Better to fail now than then.
            guard let refreshToken = OAuthManager.lastRefreshToken, !refreshToken.isEmpty else {
                providersError = "Couldn't finish signing in with Google. Try again."
                busy = false
                return
            }
            // Google's account name rides in the token: no need to ask for it.
            if parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let googleName = APIClient.name(inJWT: token) {
                parentName = googleName
            }
            let success = try await APIClient.shared.verifyParent(token: token, refreshToken: refreshToken)
            if success {
                if let error = await checkBackendAndProceed() { providersError = error }
            } else {
                providersError = "Couldn't finish signing in with Google. Try again."
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
    let onSaved: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var busy = false
    @State private var errorText: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Only reached when the sign-in didn't bring a name (an email sign-up):
    // Apple and Google ones skip it. Just the name, saved on Continue.
    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: "What's your name?",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 1,
            onBack: onBack,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // "Name", not "First name" (2026-11-12, the user's call).
                    OnboardingV2EditableField(label: "Name", text: $name, placeholder: "e.g. Sarah", contentType: .givenName, autoFocus: true)

                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(busy ? "Saving…" : "Continue", role: .parent) {
                    Task { await save() }
                }
                .disabled(busy || trimmed.isEmpty)
            }
        )
    }

    private func save() async {
        if DemoMode.previewsOnboarding { onSaved(); return }
        busy = true
        errorText = nil
        do {
            try await ParentProfile.shared.saveNow(trimmed)
            busy = false
            onSaved()
        } catch {
            busy = false
            errorText = "Couldn't save your name. \(error.apiUserMessage)"
        }
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
                        label: "I accept the",
                        linkText: "Terms of Use",
                        checked: $agreedTerms,
                        onTapLink: { showTermsSheet = true }
                    )
                    AgreementCheckRow(
                        label: "I accept the",
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
            Group {
            AgreementDocSheet(title: "Terms of Use", sections: BetaAgreementContent.termsSections)
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPrivacySheet) {
            Group {
            AgreementDocSheet(title: "Privacy Policy", sections: BetaAgreementContent.privacySections)
        }
            .presentationDragIndicator(.visible)
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
        // Bigger across the board — checkbox, row height, and text were
        // all sized like a fine-print footnote for something that's
        // actually the one required approval gating the whole flow.
        HStack(spacing: Spacing.lg) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 28))
                .foregroundStyle(checked ? OnboardingV2Theme.Palette.secondary
                                          : OnboardingV2Theme.Palette.outline)

            // One line, bigger, the document's name in bold green with no
            // underline (2026-11-13, the user's call: "I agree and accept
            // the" put the name on a second line). The name is its own
            // button, opening the document; the rest of the row ticks the box.
            HStack(spacing: 5) {
                Text(label)
                    .font(Evlin.Typography.font(17, weight: .medium))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Button(action: onTapLink) {
                    Text(linkText)
                        .font(Evlin.Typography.font(17, weight: .bold))
                        // The deep green, #2E7D32, with the ticks (2026-11-15,
                        // the user's call: the bright button green, tried the
                        // same day, was harsh on the eyes).
                        .foregroundStyle(OnboardingV2Theme.Palette.secondary)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 68)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OnboardingV2Theme.Palette.surfaceLowest)
        )
        // A plain card with a hairline, ticked or not: the checkbox says
        // which (a green-tinted card read muddy, 2026-11-08).
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { checked.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Read the \(linkText)", onTapLink)
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
            .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
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
            stepIndex: 6,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 3,
            onBack: onBack,
            content: {
                VStack(spacing: Spacing.lg) {
                    // The one thing to read, first: where the code comes from
                    // (2026-11-12, the user's call; "Connect Your Child's
                    // Device" over it as the title before).
                    Text("Grab your child's device, open Evlin and tap **Child**.")
                        .onboardingV2TitleL()
                        .fontWeight(.semibold)
                        .lineSpacing(3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    PairCodeEntry(accent: OnboardingV2Theme.Palette.primary) { code in
                        if DemoPairBridge.isOn {
                            guard let state = DemoPairBridge.read(), state.code == code, !state.paired else {
                                throw DemoPairBridge.wrongCode
                            }
                            DemoPairBridge.update { $0.paired = true }
                            onPaired(state.kidName ?? "")
                            return
                        }
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
    /// The kid's iPad pairs before it's named (2026-11-09), so the name may
    /// still be the server's placeholder.
    private var hasName: Bool { !["your kid", "your child"].contains(name.lowercased()) }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "3 · Pair",
            stepIndex: 7,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 4,
            onBack: onBack,
            content: {
                VStack(spacing: Spacing.xl) {
                    // Evlin's leaf, approved; just the name under it.
                    LeafApprovedBadge(size: 128)
                    Text(hasName ? "Connected to \(name)" : "Connected").onboardingV2TitleL()
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
    /// The account line ends "come back to Evlin." in bold green
    /// (2026-11-13, the user's call: say to return once done).
    private func comeBack(_ lead: String, then rest: String = "") -> AttributedString {
        var tail = AttributedString("come back to Evlin")
        tail.foregroundColor = OnboardingV2Theme.Palette.secondary
        tail.font = Evlin.Typography.font(16, weight: .bold)
        return AttributedString(lead) + tail + AttributedString("." + rest)
    }

    var kidName: String = ""
    let onReady: () -> Void
    var onBack: (() -> Void)? = nil

    /// The kid's name as the linked Demo simulator types it (`DemoPairBridge`).
    @State private var bridgedName: String?
    /// Family Sharing's hand-off from the kid's device (`FamilySharingHandOff`).
    @State private var stage: FamilySharingHandOff.Stage?

    private var showsSteps: Bool { stage == .accountCreated }
    /// The kid's device shows how to make the child's account: Open Settings
    /// and "I've created the account" here (2026-11-11, the user's call).
    private var creatingAccount: Bool { stage == .creatingAccount }
    /// The child this phone is waiting for, for the server's hand-off.
    @State private var childId: String?
    /// Back in Evlin after leaving it (Open Settings, or on their own):
    /// "I've created the account" leads.
    @State private var cameBack = false
    /// Open Settings was tapped: only a return after it counts (2026-11-12).
    @State private var wentToSettings = false
    /// When the parent tapped "I've created the account" here: a read of
    /// the old stage just after is ignored.
    @State private var saidCreatedAt: Date?
    @Environment(\.scenePhase) private var scenePhase
    /// What the kid's device is, "ipad" or "iphone", as it said when it
    /// paired (`DeviceKind`; 2026-11-13). Nil: just "device".
    @State private var kidKind: String?
    private var kidsDevice: String {
        let what = DeviceKind.name(kidKind) ?? "device"
        return hasName ? "\(name)'s \(what)" : "your child's \(what)"
    }

    private var name: String {
        let t = (bridgedName ?? kidName).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your child" : t
    }
    /// The child's device pairs before it's named, so the name may still be
    /// missing or the server's placeholder; it arrives once typed there.
    private var hasName: Bool { !["your kid", "your child"].contains(name.lowercased()) }

    // The parent goes into the app only once the kid's device has finished
    // its own setup (Screen Time access, the apps to lock): the server hears
    // it from the kid's device (devices.setup_completed_at) and this checks
    // every few seconds. Until then it stays pending: no button to skip it
    // and no Back (2026-11-10, the user's call; Let's begin took the parent
    // in at once before).
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
            onBack: nil,
            scrollBar: showsSteps,
            content: {
                // Paired, the parent's phone goes no further (2026-11-10,
                // the user's call): Evlin's leaf with its OK, "Connected to
                // Mia", and one line sending the parent to the child's
                // device, where the name, Family Sharing and Screen Time
                // are done. It waits here until that device is finished.
                // Reopening Evlin comes back to this same screen. (Before:
                // a Connected step with Continue, then this screen with the
                // child's device's sign-in walkthrough and Let's begin.)
                // Once the parent has created the child's account (the kid's
                // device plays how, then holds still), the leaf turns into
                // the steps for signing the kid's device in with it, here on
                // the parent's phone, and back again once it's signed in
                // (2026-11-11, the user's call; the kid's device played them
                // itself before).
                ZStack {
                    if showsSteps {
                        steps.transition(.leafMorph(spin: -6))
                    } else {
                        connected.transition(.leafMorph(spin: 24))
                    }
                }
                .animation(.spring(response: 0.75, dampingFraction: 0.86), value: showsSteps)
            },
            footer: {
                if creatingAccount && !showsSteps {
                    accountButtons
                } else {
                    waitingLine
                }
            }
        )
        .task { await waitForKid() }
        .sensoryFeedback(.success, trigger: showsSteps) { _, now in now }
        .sensoryFeedback(.success, trigger: stage == .signedIn) { _, now in now }
        .onChange(of: scenePhase) { old, now in
            // Leaving Evlin any way counts, not only through Open Settings
            // (2026-11-13: a parent who swiped home to Settings came back to
            // Open Settings alone). Control Center and Notification Center
            // never reach the background, so they still don't count.
            if now == .background, creatingAccount { wentToSettings = true }
            if now == .active, old != .active, creatingAccount, wentToSettings {
                withAnimation(.smooth(duration: 0.3)) { cameBack = true }
            }
        }
    }

    /// While the kid's device shows how to make the account: Settings is a
    /// tap away, and once back the parent can say it's done here as well
    /// as there (2026-11-11, the user's call).
    private var accountButtons: some View {
        VStack(spacing: 10) {
            if cameBack {
                OnboardingV2PrimaryButton("I've created the account", role: .parent) {
                    saidCreatedAt = Date()
                    FamilySharingHandOff.parentAccountCreated(childId: childId)
                    withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) { stage = .accountCreated }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // No second Open Settings under it (2026-11-12, the user's call).
            } else {
                OnboardingV2PrimaryButton("Open Settings", systemImage: "gearshape", role: .parent, action: openSettings)
            }
        }
        .animation(.smooth(duration: 0.3), value: cameBack)
    }

    // Apps can only open their own page in Settings (Settings' other pages
    // are private URLs, and App Review rejects them): the parent taps
    // "Settings" at its top left to get to Apple Account.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        wentToSettings = true
        UIApplication.shared.open(url)
    }

    private var waitingLine: some View {
                // Pending: what it's waiting for, with a small spinner.
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(OnboardingV2Theme.Palette.onSurfaceVariant)
                    Text("Waiting for \(name)'s device")
                        .font(Evlin.Typography.font(15, weight: .medium))
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
    }

    private var connected: some View {
        VStack(spacing: Spacing.xl) {
            LeafApprovedBadge(size: 128)
            VStack(spacing: 12) {
                Text(hasName ? "Connected to \(name)" : "Connected")
                    .onboardingV2TitleL()
                    .multilineTextAlignment(.center)
                // One short line, the same all the way (2026-11-11, the
                // user's call: people don't read long text, and that's all
                // there is to do). Tried the same day: "Look at Mia's device
                // to finish setup.", "Let's finish setting up Mia's
                // device.", "Grab Mia's device." alone, and messages that
                // changed with the Family Sharing answer.
                Text(creatingAccount
                     ? comeBack("Create \(hasName ? name : "your child")'s child account, then ",
                                then: " Not sure how? The steps are on \(kidsDevice).")
                     : AttributedString(stage == .signedIn
                        // Heard from the kid's device (2026-11-12).
                        ? "\(kidsDevice.prefix(1).uppercased() + kidsDevice.dropFirst()) is signed in. Finish setup on it."
                        : "Grab \(kidsDevice) and finish setup."))
                    .font(Evlin.Typography.font(16, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
    }

    /// "Now pick up **Mia's device** and sign it in as a child."
    private var signInLine: AttributedString {
        var device = AttributedString("\(hasName ? name : "your child")'s device")
        device.font = Evlin.Typography.font(17, weight: .bold)
        device.foregroundColor = OnboardingV2Theme.Palette.onSurface
        // What to pick up and which account (2026-11-12, the user's call:
        // "Sign … in with the new account. Follow these steps on it." was
        // unclear).
        // The name once (2026-11-12, the user's call: "… and sign Mia in."
        // named the child twice); the steps under it say how.
        // "as a child": Apple's own "Sign in a Child in My Family", step 3
        // (2026-11-12, the user's call).
        return AttributedString("Now pick up ") + device + AttributedString(" and sign it in as a child.")
    }

    /// Signing the kid's device in with the account just made: the drawn
    /// steps, to follow on that device.
    private var steps: some View {
        VStack(spacing: 14) {
            // Plain orders, the child's device in bold: it's that device, not
            // this phone, that signs in (2026-11-11, the user's call; "Not
            // sure how to sign …'s device in? Follow these steps on it." and
            // "Now sign …'s device in with the new account." before).
            Text(signInLine)
                .font(Evlin.Typography.font(17, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            // Both steps down the page, each its words beside a small
            // drawing (2026-11-12, the user's call; a carousel turning by
            // itself before, and a third step, "Then allow Screen Time …
            // and you're done", removed the same day).
            FamilySharingStepList(kidName: hasName ? name : "your child", part: .iPad)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func take(_ read: FamilySharingHandOff.Stage?) {
        // Just after "I've created the account" here, the server may still
        // say the kid's device is creating it.
        if read == .creatingAccount, let t = saidCreatedAt, Date().timeIntervalSince(t) < 15 { return }
        if read != stage { stage = read }
        if read != .creatingAccount, cameBack || wentToSettings { cameBack = false; wentToSettings = false }
    }

    private func waitForKid() async {
        if DemoPairBridge.isOn {
            // Linked Demo simulators: on when the kid's device finishes.
            while !Task.isCancelled {
                let state = DemoPairBridge.read()
                if let n = state?.kidName, !n.isEmpty, n != bridgedName { bridgedName = n }
                if let k = state?.kidDevice, k != kidKind { kidKind = k }
                take(state?.setupStage.flatMap(FamilySharingHandOff.Stage.init))
                if state?.kidDone == true { onReady(); return }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            return
        }
        if DemoMode.previewsOnboarding {
            // Long enough to see the how-to in the Demo walkthrough.
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { onReady() }
            return
        }
        while !Task.isCancelled {
            if let kids = try? await APIClient.shared.fetchChildren() {
                let paired = kids.filter(\.isPaired)
                let mine = paired.first { $0.id == SessionManager.shared.activeChildId }
                if let n = mine?.name, !n.isEmpty, n != bridgedName { bridgedName = n }
                if let k = (mine ?? paired.first)?.deviceKind, k != kidKind { kidKind = k }
                if let id = (mine ?? paired.first)?.id, id != childId { childId = id }
                take((mine ?? paired.first)?.setupStage.flatMap(FamilySharingHandOff.Stage.init))
                // The kid just paired, else any paired kid (a parent coming
                // back to onboarding after closing the app).
                let done = mine.map { $0.setupComplete != false }
                    ?? paired.contains { $0.setupComplete != false }
                if done {
                    onReady()
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

/// The leaf turning into the Family Sharing steps and back: the one going
/// shrinks, turns and blurs away while the other grows out of its middle.
private struct LeafMorph: ViewModifier {
    let gone: Double
    let spin: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.6 * gone)
            .rotationEffect(.degrees(spin * gone))
            .blur(radius: 16 * gone)
            .opacity(1 - gone)
    }
}

private extension AnyTransition {
    static func leafMorph(spin: Double) -> AnyTransition {
        .modifier(active: LeafMorph(gone: 1, spin: spin), identity: LeafMorph(gone: 0, spin: spin))
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
    @Environment(\.horizontalSizeClass) private var hSizeClass

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
                        // Bigger and darker (2026-11-11, the user's call:
                        // 11.5pt was too small to read).
                        let big = hSizeClass == .regular
                        HStack(spacing: big ? 8 : 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: big ? 17 : 14, weight: .bold))
                            Text("Also stops \(kid) from deleting Evlin")
                                .font(Evlin.Typography.font(big ? 18 : 14.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, big ? 16 : 12)
                        .padding(.vertical, big ? 10 : 8)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .padding(.top, big ? 14 : 10)
                    }
                    // A size that leaves room round it: full width on the
                    // iPad made it a metre tall, pushed the steps off and
                    // ran into the buttons (2026-11-09).
                    .frame(maxWidth: hSizeClass == .regular ? 440 : 340)
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: hSizeClass == .regular ? 18 : 14) {
                    OnboardingV2NumberedStep(number: 1, text: "Open Settings → Screen Time")
                    OnboardingV2NumberedStep(number: 2, text: "Tap \u{201C}Lock Screen Time Settings\u{201D}")
                    OnboardingV2NumberedStep(number: 3, text: "Pick a 4-digit code \(kid) won't guess")
                    }
                    .padding(.top, hSizeClass == .regular ? 8 : 4)
                }
                .padding(.bottom, hSizeClass == .regular ? 28 : 16)
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

            // Bigger (2026-11-11, the user's call: 17pt / 13.5pt were too
            // small and hard to read).
            VStack(alignment: .leading, spacing: isRegular ? 18 : 14) {
                Text("Did you set the Screen Time passcode?")
                    .font(Evlin.Typography.font(isRegular ? 28 : 21, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Without it set on the device, \(kidName) could bypass everything Evlin does.")
                    .font(Evlin.Typography.font(isRegular ? 21 : 16.5, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    OnboardingV2PrimaryButton("Yes, I set it", role: .parent, action: onConfirm)
                    OnboardingV2SecondaryButton("Not yet", action: onNotYet)
                }
                .padding(.top, 2)
            }
            .padding(isRegular ? 28 : 22)
            .background(OnboardingV2Theme.Palette.surfaceLowest)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
            .padding(.horizontal, 24)
            // Wide enough on the iPad for the bigger question on one line.
            .frame(maxWidth: isRegular ? 720 : .infinity)
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

            // The growing leaf, as on the kid's All set!: earth rises, the
            // plant shoots up and opens in its ring (2026-11-12, the user's
            // call; a habit ring filling round a sprout, HabitsTodayArt,
            // before).
            GoalsEmptyStart(action: onEnter, wordsShown: false,
                            plantSize: isRegular ? 210 : 170, gap: OnboardingV2Theme.Palette.surface)

            Text("Healthy habits start today.")
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
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 2,
            onBack: onBack,
            content: {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    OnboardingV2NotificationPrompt()
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        OnboardingV2PrimaryButton("Allow", role: .parent) {
                            Task { await requestThenAdvance() }
                        }
                        .disabled(requesting)
                        .frame(maxWidth: 600)
                    }
                    .frame(maxWidth: .infinity)
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
