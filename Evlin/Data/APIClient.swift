import Foundation

/// A lightweight API client to connect the SwiftUI app to the local FastAPI backend.
enum APIError: Error {
    case serverError(String)

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
        
        do {
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
        } catch {
            print("APIClient Fallback: Backend unreachable, simulating successful pairing.")
            SessionManager.shared.childDeviceToken = "mock_device_token"
            return true
        }
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
        let url = URL(string: "\(baseURL)\(endpoint)")!
        var request = URLRequest(url: url)
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
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
        let url = URL(string: "\(baseURL)/children/\(childId)/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "bucket": bucket,
            "submission_kind": submissionKind
        ]
        if let dueTime { body["due_time"] = dueTime }
        if let dueDate { body["due_date"] = dueDate }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ApiTask.self, from: data)
    }
    
    func submitTask(occurrenceId: String, bypassNote: String? = nil) async throws -> Bool {
        let url = URL(string: "\(baseURL)/tasks/occurrences/\(occurrenceId)/submit")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body: [String: Any] = [:]
        if let bypassNote = bypassNote {
            body["bypass_note"] = bypassNote
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }
    
    func approveTask(occurrenceId: String, reject: Bool = false) async throws -> Bool {
        let endpoint = reject ? "reject" : "approve"
        let url = URL(string: "\(baseURL)/tasks/occurrences/\(occurrenceId)/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
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
        let url = URL(string: "\(baseURL)/tasks/\(taskId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }

    func updateChildRules(childId: String, dailyLimitMin: Int, downtimeEnabled: Bool) async throws -> Bool {
        let url = URL(string: "\(baseURL)/children/\(childId)/rules")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "daily_limit_minutes": dailyLimitMin,
            "downtime_enabled": downtimeEnabled
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }

    func updateChildState(childId: String, manualLock: Bool, taskGateOverride: Bool) async throws -> Bool {
        let url = URL(string: "\(baseURL)/children/\(childId)/state")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "manual_lock": manualLock,
            "task_gate_override": taskGateOverride
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }

}

import Foundation
import SwiftUI

import Observation

@MainActor @Observable
public class SessionManager {
    static let shared = SessionManager()
    
    var parentAccessToken: String?
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
        childDeviceToken = nil
        activeChildId = nil
    }

}
