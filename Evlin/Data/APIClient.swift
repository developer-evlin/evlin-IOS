import Foundation

/// A lightweight API client to connect the SwiftUI app to the local FastAPI backend.
enum APIError: Error {
    case serverError(String)

}

extension Notification.Name {
    /// Posted when the backend says the stored login/device token is no
    /// longer valid and can't be refreshed.
    static let evlinSessionExpired = Notification.Name("EvlinSessionExpired")
}

/// A non-2xx answer from the backend, with the status and FastAPI's `detail`.
struct APIFailure: Error, LocalizedError {
    let status: Int
    let detail: String?
    var errorDescription: String? { "HTTP \(status)\(detail.map { ": \($0)" } ?? "")" }
}

extension Error {
    /// Plain-language reason for an alert. Tells "no network" apart from "the
    /// server said no" so a 401/500 isn't reported as a connection problem.
    var apiUserMessage: String {
        if let f = self as? APIFailure {
            switch f.status {
            case 401: return "Your session expired. Sign out and sign in again."
            case 404: return "The server couldn't find that child or item (\(f.detail ?? "not found"))."
            default: return "The server rejected that (\(f.status)\(f.detail.map { ": \($0)" } ?? ""))."
            }
        }
        if let u = self as? URLError {
            switch u.code {
            // iOS is telling us outright there's no route to the network, so
            // it's safe to say so plainly.
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff:
                return "You're offline. Check your internet connection and try again."

            // Reached the network but not us — a dropped Wi-Fi link, DNS, a
            // VPN or captive portal, or the server genuinely being down.
            // We can't tell which from here, so don't claim they're offline;
            // point at the one thing they can actually check. (-1004 landed
            // in the old generic branch and read as "the server is broken",
            // which is the least likely cause and the least useful thing to
            // tell someone.)
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted:
                return "Couldn't reach Evlin. Check your internet connection and try again."

            case .timedOut:
                return "Evlin took too long to answer — it may be waking up. Try again in a moment."

            case .cancelled:
                return "That was cancelled before it finished."

            default:
                return "Couldn't reach Evlin (\(u.code.rawValue)). Check your connection and try again."
            }
        }
        return "Unexpected error: \(localizedDescription)"
    }
}

@MainActor
class APIClient {
    static let shared = APIClient()
    
    // The Demo build gets an address that can't resolve (`.invalid` is
    // reserved), so nothing it does can reach the real server.
    #if EVLIN_DEMO
    let baseURL = "https://demo.invalid"
    #else
    let baseURL = "https://evlin-ios.onrender.com"
    #endif

    // 15-second request timeout so unreachable backends fail fast instead
    // of hanging for the default 60 seconds, which freezes the UI. Settable
    // only so the tests can answer requests themselves (EvlinTests).
    var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // For the few requests that wait on something slow (a chat reply waits
    // on the model). Its own session rather than a per-request timeout,
    // because the session's 15 s isn't reliably overridden by the request's.
    private let slowSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        return URLSession(configuration: config)
    }()
    
    // Tokens and active child state are now managed by SessionManager
    
    // MARK: - Authentication & Pairing
    
    
    // MARK: - Email Auth
    
    /// Email sign-up, step 1: the server emails a 6-digit code. It answers
    /// the same way whether or not the address already has an account (an
    /// existing one is emailed a "sign in instead" note), so this never says
    /// which. Returns the seconds to wait before offering "resend". Throws
    /// `APIFailure` 429 with a "wait" message when asked too often.
    func startSignup(email: String) async throws -> Int {
        let data = try await sendAnonymous("POST", "/auth/signup/start", body: ["email": email])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["resend_after"] as? Int ?? 60
    }

    /// Email sign-up, step 2: the account is created only now, once the
    /// code proves the address is the caller's.
    func verifySignup(email: String, password: String, code: String) async throws -> Bool {
        let data = try await sendAnonymous("POST", "/auth/signup/verify",
                                           body: ["email": email, "password": password, "code": code])
        guard storeParentSession(data) else { return false }
        await startParentSession()
        return true
    }

    /// Sign in with Apple. `nonce` is the raw value whose SHA-256 went into
    /// Apple's request; the server checks Apple's token carries that hash.
    func signInWithApple(identityToken: String, nonce: String, authorizationCode: String?,
                         fullName: String?) async throws -> Bool {
        var body: [String: Any] = ["identity_token": identityToken, "nonce": nonce]
        if let authorizationCode { body["authorization_code"] = authorizationCode }
        if let fullName, !fullName.isEmpty { body["full_name"] = fullName }
        let data = try await sendAnonymous("POST", "/auth/apple", body: body)
        guard storeParentSession(data) else { return false }
        await startParentSession()
        return true
    }

    private func storeParentSession(_ data: Data) -> Bool {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else { return false }
        SessionManager.shared.parentAccessToken = token
        SessionManager.shared.parentRefreshToken = json?["refresh_token"] as? String
        return true
    }

    func verifyParent(token: String, refreshToken: String) async throws -> Bool {
        _ = try await sendAnonymous("POST", "/auth/verify-parent", body: ["access_token": token])
        SessionManager.shared.parentAccessToken = token
        SessionManager.shared.parentRefreshToken = refreshToken
        await startParentSession()
        return true
    }

    func login(email: String, password: String) async throws -> Bool {
        guard storeParentSession(try await sendAnonymous("POST", "/auth/login", body: ["email": email, "password": password]))
        else { return false }
        await startParentSession()
        return true
    }

    private var sessionStartInFlight: Task<Void, Never>?
    /// Internal so the tests can stand in for a server without the route.
    var sessionStartRetryAfter = Date.distantPast

    /// Trades the Supabase sign-in for the phone's own session token, which
    /// keeps the parent signed in until they sign out: nothing to renew,
    /// nothing for Supabase to revoke. Runs after every sign-in, and on the
    /// next request for a parent signed in before this existed. A failure
    /// (offline, a server without /auth/session yet) keeps the Supabase
    /// tokens and tries again ten minutes later.
    func startParentSession() async {
        let s = SessionManager.shared
        guard s.parentSessionToken == nil, s.parentAccessToken != nil else { return }
        if let inFlight = sessionStartInFlight { return await inFlight.value }
        guard Date() >= sessionStartRetryAfter else { return }
        let task = Task { @MainActor in
            await refreshParentTokenIfExpiring()
            var data = try? await sendOnce("POST", "/auth/session", body: nil)
            if data == nil, await refreshParentToken() == .refreshed {
                data = try? await sendOnce("POST", "/auth/session", body: nil)
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = json["session_token"] as? String else {
                sessionStartRetryAfter = Date().addingTimeInterval(600)
                return
            }
            s.parentSessionToken = session
            s.parentAccessToken = nil
            s.parentRefreshToken = nil
        }
        sessionStartInFlight = task
        await task.value
        sessionStartInFlight = nil
    }

    /// Sign out on the server (best effort: the phone forgets the token
    /// either way).
    func endParentSession(_ token: String) async {
        var request = URLRequest(url: URL(string: "\(baseURL)/auth/logout")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    func deleteAccount() async throws {
        try await send("DELETE", "/auth/account")
    }

    // MARK: - Pairing (the kid's device shows a code; a parent claims it)

    struct PairingRequestResult { let code: String; let secret: String }

    /// Kid's device: start pairing. Show `code` as text and a QR, then poll
    /// `pairingStatus`. `secret` proves later that this device is the one that asked.
    func requestPairing(childName: String?) async throws -> PairingRequestResult {
        // "ipad" or "iphone", so the parent's phone can name the child's
        // device (2026-11-13; "ios" before).
        var body: [String: Any] = ["platform": DeviceKind.current]
        if let childName, !childName.isEmpty { body["child_name"] = childName }
        let json = try JSONSerialization.jsonObject(with: try await sendAnonymous("POST", "/auth/pairing/request", body: body)) as? [String: Any]
        guard let code = json?["code"] as? String, let secret = json?["secret"] as? String else {
            throw APIError.serverError("Failed to decode response")
        }
        return PairingRequestResult(code: code, secret: secret)
    }

    /// Kid's device: has a parent claimed the code yet? On success the device
    /// token is stored in the session.
    func pairingStatus(code: String, secret: String) async throws -> ApiChild? {
        let data = try await sendAnonymous("POST", "/auth/pairing/status", body: ["code": code, "secret": secret])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["status"] as? String == "paired", let token = json?["access_token"] as? String else { return nil }
        SessionManager.shared.childDeviceToken = token
        let childData = try JSONSerialization.data(withJSONObject: json?["child"] ?? [:])
        let child: ApiChild = try decode(childData)
        SessionManager.shared.activeChildId = child.id
        return child
    }

    /// Parent: attach the device showing `code` to a child. With no `childId`
    /// the backend uses an unpaired profile or makes a new one.
    @discardableResult
    func claimPairing(code: String, childId: String? = nil, newChild: Bool = false) async throws -> ApiChild {
        var body: [String: Any] = ["code": code]
        if let childId { body["child_id"] = childId }
        if newChild { body["new_child"] = true }
        return try decode(try await send("POST", "/auth/pairing/claim", body: body))
    }

    /// Request without the session's token (the kid isn't signed in yet).
    private func sendAnonymous(_ method: String, _ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIFailure(status: http.statusCode, detail: detail.map { "\($0)" })
        }
        return data
    }
    
    // MARK: - API Fetching
    
    private func fetch<T: Codable>(endpoint: String) async throws -> T {
        try decode(try await send("GET", endpoint))
    }

    /// The kid's own profile (device token), used to show the name the
    /// parent sees.
    func fetchMyChild() async throws -> ApiChild {
        try await fetch(endpoint: "/device/me")
    }
    
    func fetchChildren() async throws -> [ApiChild] {
        try await fetch(endpoint: "/children")
    }
    
    func fetchTasks(childId: String) async throws -> [ApiTask] {
        try await fetch(endpoint: "/children/\(childId)/tasks")
    }
    
    func fetchOccurrences(childId: String, dueDate: String = CalendarSync.isoDay(Date())) async throws -> [ApiOccurrence] {
        try await fetch(endpoint: "/children/\(childId)/occurrences?target_date=\(dueDate)")
    }
    
    func fetchRules(childId: String) async throws -> ApiChildRule {
        try await fetch(endpoint: "/children/\(childId)/rules")
    }
    
    func fetchState(childId: String) async throws -> ApiChildState {
        try await fetch(endpoint: "/children/\(childId)/state")
    }

    // MARK: - Generic request helper

    /// Sends an authenticated JSON request and returns the body of a 2xx
    /// response; anything else throws, so callers can't mistake a failed
    /// write for a saved one.
    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil,
                      signOutOnUnauthorized: Bool = true, timeout: TimeInterval? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await send(method, path, bodyData: data, signOutOnUnauthorized: signOutOnUnauthorized, timeout: timeout)
    }

    /// Sends one of the app's writes (see `APIClient.Write`).
    @discardableResult
    func send(_ write: WriteRequest) async throws -> Data {
        try await send(write.method, write.path, bodyData: write.body)
    }

    private func send(_ method: String, _ path: String, bodyData body: Data?,
                      signOutOnUnauthorized: Bool = true, timeout: TimeInterval? = nil) async throws -> Data {
        // The Demo build never talks to the server (DemoMode). Sync and the
        // outbox already stop short; this catches the screens that call the
        // API themselves (chat's thread list did), whose stand-in token the
        // server answered with a 401 that signed the demo out.
        if DemoMode.isBuild { throw URLError(.notConnectedToInternet) }
        // A parent still on Supabase tokens (signed in before session tokens
        // existed) moves onto one here, once.
        await startParentSession()
        await refreshParentTokenIfExpiring()
        do {
            return try await sendOnce(method, path, body: body, timeout: timeout)
        } catch let failure as APIFailure where failure.status == 401 {
            guard signOutOnUnauthorized else { throw failure }
            let s = SessionManager.shared
            if s.parentSessionToken != nil {
                // The phone's own session. It's refused only after Sign out
                // or account deletion, but a 401 from one route proves
                // nothing on its own: ask the route that answers only "is
                // this phone still signed in".
                guard await parentSessionEnded() else { throw failure }
            } else if s.parentAccessToken != nil {
                // Supabase access tokens last about an hour: trade the refresh
                // token for a new one and retry once.
                switch await refreshParentToken() {
                case .refreshed: return try await sendOnce(method, path, body: body, timeout: timeout)
                case .unreachable: throw failure // don't sign out over a network blip
                case .rejected: break
                }
            } else if SessionManager.shared.childDeviceToken != nil {
                // A kid's phone stays paired until the parent unpairs it. A
                // 401 from one route can be that route refusing device
                // tokens, not the token being gone: ask the route that
                // answers only "is this device still paired".
                guard await kidDeviceUnpaired() else { throw failure }
            }
            // The reason travels with the notice (RootView shows it in debug
            // builds and reports it), so a sign-out is never a mystery.
            let who = s.isParent ? "parent" : "kid"
            let reason = "\(who): \(method) \(path) answered 401 (\(failure.detail ?? "no detail"))"
            NotificationCenter.default.post(name: .evlinSessionExpired, object: reason)
            throw failure
        }
    }

    /// True only when the server refuses this phone's session at /auth/me.
    private func parentSessionEnded() async -> Bool {
        do {
            _ = try await sendOnce("GET", "/auth/me", body: nil)
            return false
        } catch let failure as APIFailure {
            return failure.status == 401
        } catch {
            return false // offline: can't tell, so stay signed in
        }
    }

    /// True only when the server refuses this device's token at /device/me,
    /// which happens once the parent unpairs it or removes the child.
    private func kidDeviceUnpaired() async -> Bool {
        do {
            _ = try await sendOnce("GET", "/device/me", body: nil)
            return false
        } catch let failure as APIFailure {
            return failure.status == 401
        } catch {
            return false // offline: can't tell, so stay paired
        }
    }

    /// Whether a refused refresh means the session is really over. Supabase
    /// names the reason ("Invalid Refresh Token: Already Used", "Refresh
    /// Token Not Found", "Session Expired", "User not found"). Anything else
    /// in a 401 is the server failing to reach Supabase: the server running
    /// before the fix in routers/auth.py answered those with 401 as well.
    static func refreshTokenRefused(_ detail: String?) -> Bool {
        guard let detail = detail?.lowercased() else { return false }
        return ["refresh token", "refresh_token", "session expired", "session not found",
                "session_not_found", "user not found", "user_not_found"]
            .contains { detail.contains($0) }
    }

    private func sendOnce(_ method: String, _ path: String, body: Data?,
                          timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        let session = timeout == nil ? self.session : slowSession
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIFailure(status: http.statusCode, detail: detail.map { "\($0)" })
        }
        return data
    }

    enum RefreshResult { case refreshed, rejected, unreachable }

    /// Trades the refresh token a minute before the access token runs out,
    /// so a parent coming back after an hour away doesn't send a round of
    /// requests that all 401 first. A failure here is left to the 401 path.
    func refreshParentTokenIfExpiring() async {
        guard SessionManager.shared.parentSessionToken == nil,
              let token = SessionManager.shared.parentAccessToken,
              let expiry = Self.expiry(ofJWT: token),
              expiry.timeIntervalSinceNow < 60 else { return }
        await refreshParentToken()
    }

    /// The person's name in a Supabase access token (`user_metadata`, which
    /// Google sign-in fills from the Google account), read without checking
    /// the signature: it only pre-fills the parent's name.
    static func name(inJWT token: String) -> String? {
        guard let claims = claims(ofJWT: token),
              let meta = claims["user_metadata"] as? [String: Any] else { return nil }
        for key in ["full_name", "name"] {
            if let n = (meta[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        }
        return nil
    }

    private static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The `exp` claim of a JWT, read without checking the signature (the
    /// server does that); only used to decide when to refresh.
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
    private var refreshInFlight: Task<RefreshResult, Never>?

    /// Exchanges the stored refresh token for a new access token. Concurrent
    /// callers share one request (refresh tokens are single-use).
    @discardableResult
    func refreshParentToken() async -> RefreshResult {
        if let inFlight = refreshInFlight { return await inFlight.value }
        guard let refresh = SessionManager.shared.parentRefreshToken else { return .rejected }
        let task = Task { () -> RefreshResult in
            var request = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return .unreachable }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                // Only the server saying the refresh token is no good ends
                // the session. A 503, a 429, a proxy's error page or a 401
                // that's really an outage keeps the tokens to try again,
                // the way other apps keep you signed in offline.
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
                let refused = [401, 403].contains(http.statusCode)
                    && Self.refreshTokenRefused(detail.map { "\($0)" })
                return refused ? .rejected : .unreachable
            }
            SessionManager.shared.parentAccessToken = access
            if let newRefresh = json["refresh_token"] as? String { SessionManager.shared.parentRefreshToken = newRefresh }
            return .refreshed
        }
        refreshInFlight = task
        let result = await task.value
        refreshInFlight = nil
        return result
    }

    /// The `/live` stream request, or nil with nothing to authenticate as.
    /// Built here so the stream uses the same base URL and token as every
    /// other request; `LiveUpdates` owns the connection itself.
    func liveUpdatesRequest() -> URLRequest? {
        guard let token = SessionManager.shared.activeToken else { return nil }
        var request = URLRequest(url: URL(string: "\(baseURL)/live")!)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Parent profile

    func fetchMe() async throws -> ApiParent {
        try decode(try await send("GET", "/auth/me"))
    }

    func updateMyName(_ name: String) async throws {
        try await send(Write.updateMyName(name))
    }

    // MARK: - Screen time access code (routers/access_codes.py)

    /// The parent's code now: the one still good, or a new one.
    func accessCode() async throws -> ApiAccessCode {
        try decode(try await send("POST", "/access-code"))
    }

    /// The child's device: whether a typed code opens its settings. Right,
    /// the server uses it up.
    func checkAccessCode(_ code: String) async throws -> Bool {
        let answer: ApiAccessCodeCheck = try decode(try await send("POST", "/device/access-code", body: ["code": code]))
        return answer.ok
    }

    // MARK: - Submissions (real photo evidence)

    struct SubmissionUploadResult { let submissionId: String; let uploadURL: String }

    /// Starts a submission and gets back a one-time presigned URL to PUT the
    /// file straight to R2 — the file itself never passes through this API.
    func createSubmission(occurrenceId: String, kind: String, contentType: String) async throws -> SubmissionUploadResult {
        let data = try await send("POST", "/occurrences/\(occurrenceId)/submissions", body: [
            "kind": kind, "content_type": contentType,
        ])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadUrl = json["upload_url"] as? String,
              let submission = json["submission"] as? [String: Any],
              let submissionId = submission["id"] as? String else {
            throw APIError.serverError("Failed to decode response")
        }
        return SubmissionUploadResult(submissionId: submissionId, uploadURL: uploadUrl)
    }

    /// Uploads bytes straight to R2 via a presigned URL — not through our own
    /// backend, and not authenticated with our own bearer token (the URL
    /// itself is the credential). The Content-Type must match exactly what
    /// the URL was signed with, or R2 rejects the PUT.
    func uploadToPresignedURL(_ urlString: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func completeSubmission(id: String) async throws {
        try await send("POST", "/submissions/\(id)/complete")
    }

    func fetchSubmissions(occurrenceId: String) async throws -> [ApiSubmission] {
        try decode(try await send("GET", "/occurrences/\(occurrenceId)/submissions"))
    }

    /// A day's screen-time pool — dailyLimitMinutes (or a weekly_schedule
    /// override for that weekday) plus every grant/deduction credited to
    /// it. Defaults to today when `date` is omitted.
    func fetchTimeGrants(childId: String, date: String? = nil) async throws -> ApiTimeGrantsSummary {
        let query = date.map { "?date=\($0)" } ?? ""
        return try decode(try await send("GET", "/children/\(childId)/time-grants\(query)"))
    }

    func fetchConversations(childId: String) async throws -> [ApiChatConversation] {
        try decode(try await send("GET", "/children/\(childId)/conversations"))
    }

    func fetchConversationMessages(conversationId: String) async throws -> [ApiChatMessage] {
        try decode(try await send("GET", "/conversations/\(conversationId)/messages"))
    }

    @discardableResult
    func renameConversation(conversationId: String, title: String) async throws -> ApiChatConversation {
        try decode(try await send("PUT", "/conversations/\(conversationId)", body: ["title": title]))
    }

    func deleteConversation(conversationId: String) async throws {
        _ = try await send("DELETE", "/conversations/\(conversationId)")
    }

    /// `conversationId` continues that thread. Passing neither it nor
    /// `startNewConversation` appends to the running one, which is what an
    /// older client does by default.
    @discardableResult
    func sendChatMessage(childId: String, text: String, conversationId: String? = nil,
                         startNewConversation: Bool = false, agent: String = "chat",
                         shortcut: String? = nil) async throws -> ApiChatMessage {
        #if EVLIN_DEMO
        if let demo = await DemoMode.chatReply(childId: childId, text: text, shortcut: shortcut) { return demo }
        #endif
        // The parent's time zone, so "today" and "tomorrow" in chat are
        // theirs even before a kid's device has told the server its own.
        var body: [String: Any] = ["text": text, "agent": agent, "timezone": TimeZone.current.identifier]
        if let shortcut { body["shortcut"] = shortcut }
        if let conversationId { body["conversation_id"] = conversationId }
        if startNewConversation { body["new_conversation"] = true }
        // A reply waits on the model, which can take well past the 15 s
        // every other request gets, and the server allows it 30. At 15 the
        // phone gave up on replies the server went on to save.
        return try decode(try await send("POST", "/children/\(childId)/chat", body: body, timeout: 45))
    }

    // MARK: - App catalog

    func fetchAppCatalog() async throws -> [ApiApp] {
        try decode(try await send("GET", "/apps"))
    }

    /// This child's lockable apps — what a lock covers and a block can target.
    func fetchChildApps(childId: String) async throws -> [ApiApp] {
        try decode(try await send("GET", "/children/\(childId)/apps"))
    }

    @discardableResult
    func setChildApps(childId: String, appIds: [String]) async throws -> [ApiApp] {
        try decode(try await send("PUT", "/children/\(childId)/apps", body: ["app_ids": appIds]))
    }

    /// Kid device: what only the device knows about its child.
    @discardableResult
    /// The parent phone's zone for a child whose device hasn't reported
    /// one yet; the server only takes it while the child has none.
    func fillChildTimezone(childId: String, timezone: String) async throws {
        _ = try await send("PUT", "/children/\(childId)", body: ["timezone": timezone])
    }

    func updateMyDevice(timezone: String, setupComplete: Bool = false) async throws -> ApiChild {
        var body: [String: Any] = ["timezone": timezone]
        if setupComplete { body["setup_complete"] = true }
        return try decode(try await send("PUT", "/device/me", body: body))
    }

    // MARK: - Policy

    func fetchPolicy(childId: String) async throws -> ApiPolicy {
        try decode(try await send("GET", "/children/\(childId)/policy"))
    }

    // MARK: - App blocks

    func fetchAppBlocks(childId: String, activeOnly: Bool = true) async throws -> [ApiAppBlock] {
        try decode(try await send("GET", "/children/\(childId)/app-blocks?active=\(activeOnly)"))
    }

    /// One block per app, created together. What each kind needs:
    /// duration → durationMinutes; until_task → untilTaskId; scheduled →
    /// days + start + end ("HH:MM", the child's local time); indefinite →
    /// nothing. `addToList` puts any app not yet on the child's list onto it.
    @discardableResult
    func createAppBlocks(childId: String, appIds: [String], blockType: String,
                         durationMinutes: Int? = nil, untilTaskId: String? = nil,
                         scheduleDays: String? = nil, scheduleStart: String? = nil, scheduleEnd: String? = nil,
                         addToList: Bool = false) async throws -> [ApiAppBlock] {
        var body: [String: Any] = ["app_ids": appIds, "block_type": blockType, "add_to_list": addToList]
        if let durationMinutes { body["duration_minutes"] = durationMinutes }
        if let untilTaskId { body["until_task_id"] = untilTaskId }
        if let scheduleDays { body["schedule_days"] = scheduleDays }
        if let scheduleStart { body["schedule_start"] = scheduleStart }
        if let scheduleEnd { body["schedule_end"] = scheduleEnd }
        return try decode(try await send("POST", "/children/\(childId)/app-blocks", body: body))
    }

}

import SwiftUI
import Observation

@MainActor @Observable
public class SessionManager {
    static let shared = SessionManager()

    // Tokens live in the Keychain so the app survives being closed: a parent
    // stays signed in and a kid's phone stays paired.
    /// The phone's own Evlin session (server: models.ParentSession). Never
    /// expires and is never renewed: it ends only on Sign out or account
    /// deletion. Once a parent has one, the Supabase tokens below are gone.
    var parentSessionToken: String? { didSet { KeychainStore.set(parentSessionToken, for: "parentSession") } }
    /// Supabase's tokens, only between signing in and getting the session
    /// token above (or with a server that can't issue one yet).
    var parentAccessToken: String? { didSet { KeychainStore.set(parentAccessToken, for: "parentAccess") } }
    var parentRefreshToken: String? { didSet { KeychainStore.set(parentRefreshToken, for: "parentRefresh") } }
    var childDeviceToken: String? { didSet { KeychainStore.set(childDeviceToken, for: "childDevice") } }

    // The UUID of the child whose data is currently being viewed/managed.
    // For MVP, if a parent has multiple children, they would switch this.
    // On the kid's device, this is just their own ID.
    var activeChildId: String? { didSet { KeychainStore.set(activeChildId, for: "activeChild") } }

    init() {
        parentSessionToken = KeychainStore.get("parentSession")
        parentAccessToken = KeychainStore.get("parentAccess")
        parentRefreshToken = KeychainStore.get("parentRefresh")
        childDeviceToken = KeychainStore.get("childDevice")
        activeChildId = KeychainStore.get("activeChild")
    }

    /// iOS can start the app after a reboot before the phone is first
    /// unlocked (prewarming, a background wake). The Keychain is closed then,
    /// so `init` read nothing, which looked like being signed out. Fills in
    /// whatever is missing once it opens; never replaces a value in memory.
    func reloadMissingFromKeychain() {
        if parentSessionToken == nil, let v = KeychainStore.get("parentSession") { parentSessionToken = v }
        if parentAccessToken == nil, let v = KeychainStore.get("parentAccess") { parentAccessToken = v }
        if parentRefreshToken == nil, let v = KeychainStore.get("parentRefresh") { parentRefreshToken = v }
        if childDeviceToken == nil, let v = KeychainStore.get("childDevice") { childDeviceToken = v }
        if activeChildId == nil, let v = KeychainStore.get("activeChild") { activeChildId = v }
    }

    var activeToken: String? {
        return parentSessionToken ?? parentAccessToken ?? childDeviceToken
    }

    /// This phone is signed in as a parent (not a kid's paired device).
    var isParent: Bool { parentSessionToken != nil || parentAccessToken != nil }
    var hasParentSession: Bool { parentSessionToken != nil || parentAccessToken != nil || parentRefreshToken != nil }
    var hasChildSession: Bool { childDeviceToken != nil }

    func clear() {
        ParentProfile.shared.reset()
        Outbox.discardAll()
        LocalStore.shared.eraseAll()
        // Signing out ends this phone's session on the server too, so the
        // token is worthless even if it were copied off the phone.
        if let session = parentSessionToken {
            Task { await APIClient.shared.endParentSession(session) }
        }
        parentSessionToken = nil
        parentAccessToken = nil
        parentRefreshToken = nil
        childDeviceToken = nil
        activeChildId = nil
    }

}

// MARK: - What the deployed server supports

/// Features whose screens are built but whose server side isn't deployed yet.
/// The Demo app never talks to the server, so it shows them all; the real
/// app (Debug and Release) shows each only once the backend that stores it
/// is live, so a parent never sets something the server silently drops.
///
/// After deploying the backend, flip the matching line to `true` (or the
/// whole set) and build the app. Checked against the live server on
/// 2026-11-17 (its /openapi.json): none of these were there.
enum ServerSupport {
    #if EVLIN_DEMO
    private static let demo = true
    #else
    private static let demo = false
    #endif

    /// Chat drafts app blocks (`draft_app_block`, the `block_app` shortcut).
    /// Off: Chat's "Block an app" opens the Block an app sheet, as Profile's does.
    static let chatBlocks = demo

    /// Downtime on some days, or different hours by day
    /// (`downtime_days`, `downtime_schedule`). Off: Every Day only.
    static let downtimeByDay = demo

    /// Instant unlock (`child_state.instant_unlock`). Off: the row is hidden.
    static let instantUnlock = demo

    /// The kid's name sent from their device after pairing (`PUT /device/me`
    /// `name`). Off: the kid's device asks the name before showing its code,
    /// and it travels with the pairing request, which the live server takes.
    static let nameAfterPairing = demo

    /// The two devices passing Family Sharing setup between them
    /// (`devices.setup_stage`, `PUT /children/{id}/setup-stage`). Off: each
    /// device carries on by its own taps.
    static let familySharingHandOff = demo
    /// Editing or deleting one day of a repeating task, or the rest of it
    /// (`ApiTask.skippedDates`, `repeatUntil`; `POST /tasks/{id}/cut` and
    /// `/split`). On everywhere since 2026-11-19: needs the backend
    /// deployed before an app build (a server without those routes answers
    /// 404, the write is dropped, and the edit is undone by the next sync).
    static let taskSeriesEdits = true
}
