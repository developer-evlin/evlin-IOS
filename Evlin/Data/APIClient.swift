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
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection."
            case .timedOut:
                return "The server took too long to answer. It may be waking up — try again in a moment."
            default: return "Couldn't reach the server (\(u.code.rawValue))."
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
    // of hanging for the default 60 seconds, which freezes the UI.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    
    // Tokens and active child state are now managed by SessionManager
    
    // MARK: - Authentication & Pairing
    
    
    // MARK: - Email Auth
    
    func register(email: String, password: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let token = json?["access_token"] as? String {
            SessionManager.shared.parentAccessToken = token
            SessionManager.shared.parentRefreshToken = json?["refresh_token"] as? String
            return true
        }
        return false
    }
    
    
    func verifyParent(token: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/verify-parent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["access_token": token]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        
        SessionManager.shared.parentAccessToken = token
        return true
    }

    func login(email: String, password: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let token = json?["access_token"] as? String {
            SessionManager.shared.parentAccessToken = token
            SessionManager.shared.parentRefreshToken = json?["refresh_token"] as? String
            return true
        }
        return false
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
    
    func fetchOccurrences(childId: String) async throws -> [ApiOccurrence] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        return try await fetch(endpoint: "/children/\(childId)/occurrences?target_date=\(dateString)")
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
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        do {
            return try await sendOnce(method, path, body: body)
        } catch let failure as APIFailure where failure.status == 401 {
            let hadParent = SessionManager.shared.parentAccessToken != nil
            if hadParent {
                // Supabase access tokens last about an hour: trade the refresh
                // token for a new one and retry once.
                switch await refreshParentToken() {
                case .refreshed: return try await sendOnce(method, path, body: body)
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

    private func sendOnce(_ method: String, _ path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
                return http.statusCode >= 500 ? .unreachable : .rejected
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
        try await send("PUT", "/auth/me", body: ["name": name])
    }

    // MARK: - Children

    func updateChild(childId: String, name: String? = nil, colorIndex: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let colorIndex { body["color_index"] = colorIndex }
        try await send("PUT", "/children/\(childId)", body: body)
    }

    func deleteChild(childId: String) async throws {
        try await send("DELETE", "/children/\(childId)")
    }

    // MARK: - Calendar events

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    func fetchEvents(childId: String, from: Date, to: Date) async throws -> [ApiEvent] {
        let f = Self.isoOut
        let q = "start_date=\(f.string(from: from))&end_date=\(f.string(from: to))"
            .replacingOccurrences(of: "+", with: "%2B")
        return try decode(try await send("GET", "/children/\(childId)/events?\(q)"))
    }

    private func eventBody(childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, isParentOnly: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "title": title,
            "start_at": Self.isoOut.string(from: start),
            "end_at": Self.isoOut.string(from: end),
            "recurrence": recurrence,
            // The server always stores "manual" here regardless of what's
            // sent — there's no ICS-import feature yet, and this field
            // isn't how the parent-lane/family-wide distinction is made
            // (that's is_parent_only, below).
            "is_parent_only": isParentOnly,
        ]
        if let childId { body["child_id"] = childId }
        if let category { body["category"] = category }
        if let note { body["note"] = note }
        if let location, !location.isEmpty { body["location_or_link"] = location }
        return body
    }

    func createEvent(childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, isParentOnly: Bool) async throws -> ApiEvent {
        let body = eventBody(childId: childId, title: title, start: start, end: end, category: category, note: note, location: location, recurrence: recurrence, isParentOnly: isParentOnly)
        return try decode(try await send("POST", "/events", body: body))
    }

    func updateEvent(eventId: String, childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, isParentOnly: Bool) async throws {
        let body = eventBody(childId: childId, title: title, start: start, end: end, category: category, note: note, location: location, recurrence: recurrence, isParentOnly: isParentOnly)
        try await send("PUT", "/events/\(eventId)", body: body)
    }

    func deleteEvent(eventId: String) async throws {
        try await send("DELETE", "/events/\(eventId)")
    }

    // MARK: - Submissions (real photo/voice evidence)

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

    // MARK: - Task Management (Bi-directional Sync)
    
    /// Creates the task on the backend and returns the saved row, so callers
    /// can use the real database id instead of a locally generated one.
    func createTask(childId: String, title: String, instructions: String?, recurrence: String, category: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil) async throws -> ApiTask {
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "category": category,
            "submission_kind": submissionKind
        ]
        if let dueTime { body["due_time"] = dueTime }
        if let dueDate { body["due_date"] = dueDate }
        return try decode(try await send("POST", "/children/\(childId)/tasks", body: body))
    }
    
    func submitTask(occurrenceId: String, bypassNote: String? = nil) async throws -> Bool {
        var body: [String: Any] = [:]
        if let bypassNote { body["bypass_note"] = bypassNote }
        try await send("POST", "/tasks/occurrences/\(occurrenceId)/submit", body: body)
        return true
    }
    
    func approveTask(occurrenceId: String, reject: Bool = false) async throws -> Bool {
        try await send("POST", "/tasks/occurrences/\(occurrenceId)/\(reject ? "reject" : "approve")")
        return true
    }

    /// Parent asks for a redo; the note is shown to the kid.
    func rejectTask(occurrenceId: String, note: String?) async throws {
        var body: [String: Any] = ["status": "rejected"]
        if let note, !note.isEmpty { body["rejection_note"] = note }
        try await send("PUT", "/occurrences/\(occurrenceId)/status", body: body)
    }

    /// Kid asks to skip a task today.
    func requestBypass(occurrenceId: String, note: String?) async throws {
        try await send("POST", "/occurrences/\(occurrenceId)/bypass", body: ["bypass_note": note ?? ""])
    }

    func updateTask(taskId: String, title: String, instructions: String?, recurrence: String, category: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil) async throws -> Bool {
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "category": category,
            "submission_kind": submissionKind
        ]
        if let dueTime { body["due_time"] = dueTime }
        if let dueDate { body["due_date"] = dueDate }
        try await send("PUT", "/tasks/\(taskId)", body: body)
        return true
    }

    func deleteTask(taskId: String) async throws -> Bool {
        try await send("DELETE", "/tasks/\(taskId)")
        return true
    }

    /// Saves the whole rules picture for a child (see `RuleSync.payload`).
    func saveRules(childId: String, body: [String: Any]) async throws {
        try await send("PUT", "/children/\(childId)/rules", body: body)
    }

    func updateChildRules(childId: String, dailyLimitMin: Int, downtimeEnabled: Bool) async throws -> Bool {
        try await send("PUT", "/children/\(childId)/rules", body: [
            "daily_limit_minutes": dailyLimitMin,
            "downtime_enabled": downtimeEnabled
        ])
        return true
    }

    func updateChildState(childId: String, manualLock: Bool, taskGateOverride: Bool) async throws -> Bool {
        try await send("PUT", "/children/\(childId)/state", body: [
            "manual_lock": manualLock,
            "task_gate_override": taskGateOverride
        ])
        return true
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

    var activeToken: String? {
        return parentAccessToken ?? childDeviceToken
    }

    var hasParentSession: Bool { parentAccessToken != nil || parentRefreshToken != nil }
    var hasChildSession: Bool { childDeviceToken != nil }

    func clear() {
        ParentProfile.shared.reset()
        parentAccessToken = nil
        parentRefreshToken = nil
        childDeviceToken = nil
        activeChildId = nil
    }

}
