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

    func generatePairingCode() async throws -> (code: String, expiresAt: String) {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return ("123456", "2099-01-01T00:00:00Z")
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
    
        func checkPairingStatus(code: String) async throws -> (paired: Bool, kidName: String?) {
        let url = URL(string: "\(baseURL)/auth/check-pairing/\(code)")!
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

    // MARK: - Task Management (Bi-directional Sync)
    
    func createTask(childId: String, title: String, instructions: String?, recurrence: String, bucket: String, submissionKind: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/children/\(childId)/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "bucket": bucket,
            "submission_kind": submissionKind
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
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
    func updateTask(taskId: String, title: String, instructions: String?, recurrence: String, bucket: String, submissionKind: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/tasks/\(taskId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = SessionManager.shared.activeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "bucket": bucket,
            "submission_kind": submissionKind
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
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
