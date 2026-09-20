import Foundation

/// A lightweight API client to connect the SwiftUI app to the local FastAPI backend.
enum APIError: Error {
    case serverError(String)

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

    func deleteAccount() async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/account")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        if let token = SessionManager.shared.parentAccessToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }

    /// Asks the backend for a pairing code. With no arguments it pairs the
    /// parent's first child (onboarding); `childId` re-pairs that child;
    /// `newChild` creates another child and pairs that one.
    func generatePairingCode(childId: String? = nil, newChild: Bool = false) async throws -> (code: String, expiresAt: String, childId: String?) {
        var body: [String: Any] = [:]
        if let childId { body["child_id"] = childId }
        if newChild { body["new_child"] = true }
        let data: Data
        do {
            data = try await send("POST", "/auth/generate-pairing-code", body: body)
        } catch {
            throw APIError.serverError("Failed to generate code")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let code = json?["pairing_code"] as? String, let expiresAt = json?["expires_at"] as? String else {
            throw APIError.serverError("Failed to decode response")
        }
        return (code, expiresAt, json?["child_id"] as? String)
    }
    
    func pairChildDevice(pairingCode: String, childName: String? = nil) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/pair-child")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = ["pairing_code": pairingCode, "platform": "ios"]
        if let childName = childName, !childName.isEmpty {
            body["child_name"] = childName
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // A network failure throws (the caller shows "Network error") instead
        // of pretending pairing worked with a fake token.
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let token = json?["access_token"] as? String {
            SessionManager.shared.childDeviceToken = token
            return true
        }
        return false
    }
    
        func checkPairingStatus(code: String, childId: String? = nil) async throws -> (paired: Bool, kidName: String?) {
        let query = childId.map { "?child_id=\($0)" } ?? ""
        let url = URL(string: "\(baseURL)/auth/check-pairing/\(code)\(query)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        if let token = SessionManager.shared.parentAccessToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return (false, nil)
            }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let paired = json?["paired"] as? Bool ?? false
            let kidName = json?["kid_name"] as? String
            return (paired, kidName)
        } catch {
            return (false, nil)
        }
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
            // Supabase access tokens last about an hour: trade the refresh
            // token for a new one and retry once before giving up.
            guard SessionManager.shared.parentAccessToken != nil, await refreshParentToken() else { throw failure }
            return try await sendOnce(method, path, body: body)
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

    private var refreshInFlight: Task<Bool, Never>?

    /// Exchanges the stored refresh token for a new access token. Concurrent
    /// callers share one request (refresh tokens are single-use).
    @discardableResult
    func refreshParentToken() async -> Bool {
        if let inFlight = refreshInFlight { return await inFlight.value }
        guard let refresh = SessionManager.shared.parentRefreshToken else { return false }
        let task = Task { () -> Bool in
            var request = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else { return false }
            SessionManager.shared.parentAccessToken = access
            if let newRefresh = json["refresh_token"] as? String { SessionManager.shared.parentRefreshToken = newRefresh }
            return true
        }
        refreshInFlight = task
        let ok = await task.value
        refreshInFlight = nil
        return ok
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
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

    private func eventBody(childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, source: String) -> [String: Any] {
        var body: [String: Any] = [
            "title": title,
            "start_at": Self.isoOut.string(from: start),
            "end_at": Self.isoOut.string(from: end),
            "recurrence": recurrence,
            "source": source,
        ]
        if let childId { body["child_id"] = childId }
        if let category { body["category"] = category }
        if let note { body["note"] = note }
        if let location, !location.isEmpty { body["location_or_link"] = location }
        return body
    }

    func createEvent(childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, source: String) async throws -> ApiEvent {
        let body = eventBody(childId: childId, title: title, start: start, end: end, category: category, note: note, location: location, recurrence: recurrence, source: source)
        return try decode(try await send("POST", "/events", body: body))
    }

    func updateEvent(eventId: String, childId: String?, title: String, start: Date, end: Date, category: String?, note: String?, location: String?, recurrence: String, source: String) async throws {
        let body = eventBody(childId: childId, title: title, start: start, end: end, category: category, note: note, location: location, recurrence: recurrence, source: source)
        try await send("PUT", "/events/\(eventId)", body: body)
    }

    func deleteEvent(eventId: String) async throws {
        try await send("DELETE", "/events/\(eventId)")
    }

    // MARK: - Task Management (Bi-directional Sync)
    
    /// Creates the task on the backend and returns the saved row, so callers
    /// can use the real database id instead of a locally generated one.
    func createTask(childId: String, title: String, instructions: String?, recurrence: String, bucket: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil) async throws -> ApiTask {
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "bucket": bucket,
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

    func updateTask(taskId: String, title: String, instructions: String?, recurrence: String, bucket: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil) async throws -> Bool {
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "bucket": bucket,
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

import Foundation
import SwiftUI

import Observation

@MainActor @Observable
public class SessionManager {
    static let shared = SessionManager()
    
    var parentAccessToken: String?
    var parentRefreshToken: String?
    var childDeviceToken: String?
    
    // The UUID of the child whose data is currently being viewed/managed.
    // For MVP, if a parent has multiple children, they would switch this.
    // On the kid's device, this is just their own ID.
    var activeChildId: String?
    
    var activeToken: String? {
        return parentAccessToken ?? childDeviceToken
    }
    
    func clear() {
        parentAccessToken = nil
        parentRefreshToken = nil
        childDeviceToken = nil
        activeChildId = nil
    }

}
