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
    
    // Switch to your Render URL:
    let baseURL = "https://evlin-ios.onrender.com"

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
        return storeParentSession(data)
    }

    /// Sign in with Apple. `nonce` is the raw value whose SHA-256 went into
    /// Apple's request; the server checks Apple's token carries that hash.
    func signInWithApple(identityToken: String, nonce: String, authorizationCode: String?,
                         fullName: String?) async throws -> Bool {
        var body: [String: Any] = ["identity_token": identityToken, "nonce": nonce]
        if let authorizationCode { body["authorization_code"] = authorizationCode }
        if let fullName, !fullName.isEmpty { body["full_name"] = fullName }
        let data = try await sendAnonymous("POST", "/auth/apple", body: body)
        return storeParentSession(data)
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
        return true
    }

    func login(email: String, password: String) async throws -> Bool {
        storeParentSession(try await sendAnonymous("POST", "/auth/login", body: ["email": email, "password": password]))
    }

    func deleteAccount() async throws {
        try await send("DELETE", "/auth/account")
    }

    // MARK: - Pairing (the kid's device shows a code; a parent claims it)

    struct PairingRequestResult { let code: String; let secret: String }

    /// Kid's device: start pairing. Show `code` as text and a QR, then poll
    /// `pairingStatus`. `secret` proves later that this device is the one that asked.
    func requestPairing(childName: String?) async throws -> PairingRequestResult {
        var body: [String: Any] = ["platform": "ios"]
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
        await refreshParentTokenIfExpiring()
        do {
            return try await sendOnce(method, path, body: body, timeout: timeout)
        } catch let failure as APIFailure where failure.status == 401 {
            guard signOutOnUnauthorized else { throw failure }
            let hadParent = SessionManager.shared.parentAccessToken != nil
            if hadParent {
                // Supabase access tokens last about an hour: trade the refresh
                // token for a new one and retry once.
                switch await refreshParentToken() {
                case .refreshed: return try await sendOnce(method, path, body: body, timeout: timeout)
                case .unreachable: throw failure // don't sign out over a network blip
                case .rejected: break
                }
            }
            // Nothing left that could authenticate: sign out (the kid's device
            // token is 401 only if it was revoked or the child was removed).
            NotificationCenter.default.post(name: .evlinSessionExpired, object: nil)
            throw failure
        }
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
        guard let token = SessionManager.shared.parentAccessToken,
              let expiry = Self.expiry(ofJWT: token),
              expiry.timeIntervalSinceNow < 60 else { return }
        await refreshParentToken()
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
                // the session (it answers 401 for that and nothing else). A
                // 503, a 429 or a proxy's error page keeps the tokens to try
                // again, the way other apps keep you signed in offline.
                return [401, 403].contains(http.statusCode) ? .rejected : .unreachable
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

    // MARK: - Calendar events

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    func fetchEvents(childId: String, from: Date, to: Date) async throws -> [ApiEvent] {
        let f = Self.isoOut
        let q = "start_date=\(f.string(from: from))&end_date=\(f.string(from: to))"
            .replacingOccurrences(of: "+", with: "%2B")
        // A kid device reading its calendar never signs out over a 401: its
        // token was just accepted by /device/me in the same sync, so a 401
        // here only means a server from before kids could read events.
        let isKidDevice = SessionManager.shared.parentAccessToken == nil
        return try decode(try await send("GET", "/children/\(childId)/events?\(q)", signOutOnUnauthorized: !isKidDevice))
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
                         shortcut: String? = nil, regenerate: Bool = false) async throws -> ApiChatMessage {
        // The parent's time zone, so "today" and "tomorrow" in chat are
        // theirs even before a kid's device has told the server its own.
        var body: [String: Any] = ["text": text, "agent": agent, "timezone": TimeZone.current.identifier]
        if let shortcut { body["shortcut"] = shortcut }
        if regenerate { body["regenerate"] = true }
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
    func updateMyDevice(timezone: String) async throws -> ApiChild {
        try decode(try await send("PUT", "/device/me", body: ["timezone": timezone]))
    }

    // MARK: - Today's videos

    func fetchVideoProfile(childId: String) async throws -> ApiVideoProfile {
        try decode(try await send("GET", "/children/\(childId)/video-profile"))
    }

    /// Partial: only the fields passed change.
    @discardableResult
    func updateVideoProfile(childId: String, allowedCategories: [String]? = nil,
                            blockedKeywords: [String]? = nil,
                            allowedChannels: [ApiVideoChannel]? = nil,
                            blockedChannels: [ApiVideoChannel]? = nil,
                            dailyMinutes: Int? = nil, maxVideoMinutes: Int? = nil) async throws -> ApiVideoProfile {
        var body: [String: Any] = [:]
        if let allowedCategories { body["allowed_categories"] = allowedCategories }
        if let blockedKeywords { body["blocked_keywords"] = blockedKeywords }
        if let allowedChannels { body["allowed_channels"] = allowedChannels.map { ["id": $0.id, "title": $0.title] } }
        if let blockedChannels { body["blocked_channels"] = blockedChannels.map { ["id": $0.id, "title": $0.title] } }
        if let dailyMinutes { body["daily_minutes"] = dailyMinutes }
        if let maxVideoMinutes { body["max_video_minutes"] = maxVideoMinutes }
        return try decode(try await send("PUT", "/children/\(childId)/video-profile", body: body))
    }

    /// Both sides: the parent's view of the list, and the child's player.
    func fetchVideoQueue(childId: String) async throws -> ApiVideoQueue {
        try decode(try await send("GET", "/children/\(childId)/video-queue"))
    }

    /// The parent's approval — the one way a video reaches the child.
    /// `replace` swaps out whatever is still unwatched today.
    @discardableResult
    func addToVideoQueue(childId: String, videos: [VideoSuggestion], replace: Bool) async throws -> ApiVideoQueue {
        let list: [[String: Any]] = videos.map {
            ["video_id": $0.videoId, "title": $0.title, "channel_id": $0.channelId,
             "channel_title": $0.channelTitle, "thumbnail_url": $0.thumbnailUrl,
             "duration_seconds": $0.durationSeconds, "category": $0.category]
        }
        return try decode(try await send("POST", "/children/\(childId)/video-queue",
                                         body: ["videos": list, "replace": replace]))
    }

    @discardableResult
    func reorderVideoQueue(childId: String, itemIds: [String]) async throws -> ApiVideoQueue {
        try decode(try await send("PUT", "/children/\(childId)/video-queue/order", body: ["item_ids": itemIds]))
    }

    func removeFromVideoQueue(itemId: String) async throws {
        try await send("DELETE", "/video-queue/\(itemId)")
    }

    /// Kid device: seconds actually played. The server only moves it forward.
    @discardableResult
    func reportVideoProgress(itemId: String, watchedSeconds: Int, completed: Bool) async throws -> ApiVideoQueueItem {
        try decode(try await send("POST", "/video-queue/\(itemId)/progress",
                                  body: ["watched_seconds": watchedSeconds, "completed": completed]))
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
    var parentAccessToken: String? { didSet { KeychainStore.set(parentAccessToken, for: "parentAccess") } }
    var parentRefreshToken: String? { didSet { KeychainStore.set(parentRefreshToken, for: "parentRefresh") } }
    var childDeviceToken: String? { didSet { KeychainStore.set(childDeviceToken, for: "childDevice") } }

    // The UUID of the child whose data is currently being viewed/managed.
    // For MVP, if a parent has multiple children, they would switch this.
    // On the kid's device, this is just their own ID.
    var activeChildId: String? { didSet { KeychainStore.set(activeChildId, for: "activeChild") } }

    init() {
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
        if parentAccessToken == nil, let v = KeychainStore.get("parentAccess") { parentAccessToken = v }
        if parentRefreshToken == nil, let v = KeychainStore.get("parentRefresh") { parentRefreshToken = v }
        if childDeviceToken == nil, let v = KeychainStore.get("childDevice") { childDeviceToken = v }
        if activeChildId == nil, let v = KeychainStore.get("activeChild") { activeChildId = v }
    }

    var activeToken: String? {
        return parentAccessToken ?? childDeviceToken
    }

    var hasParentSession: Bool { parentAccessToken != nil || parentRefreshToken != nil }
    var hasChildSession: Bool { childDeviceToken != nil }

    func clear() {
        ParentProfile.shared.reset()
        Outbox.discardAll()
        LocalStore.shared.eraseAll()
        parentAccessToken = nil
        parentRefreshToken = nil
        childDeviceToken = nil
        activeChildId = nil
    }

}
