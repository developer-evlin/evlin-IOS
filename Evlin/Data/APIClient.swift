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
    
    /// Throws the backend's real `APIFailure` (with its `detail`) on
    /// anything but 2xx, instead of the plain `Bool` this used to return —
    /// a wrong password and a rate-limited/duplicate-email/disabled-account
    /// error used to look identical to the caller, which always fell back
    /// to one of two generic hardcoded strings ("Failed to create account."
    /// / "Incorrect email or password.") no matter what actually went wrong.
    func register(email: String, password: String) async throws -> Bool {
        let data = try await sendAnonymous("POST", "/auth/register", body: ["email": email, "password": password])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else { return false }
        SessionManager.shared.parentAccessToken = token
        SessionManager.shared.parentRefreshToken = json?["refresh_token"] as? String
        return true
    }

    func verifyParent(token: String) async throws -> Bool {
        _ = try await sendAnonymous("POST", "/auth/verify-parent", body: ["access_token": token])
        SessionManager.shared.parentAccessToken = token
        return true
    }

    func login(email: String, password: String) async throws -> Bool {
        let data = try await sendAnonymous("POST", "/auth/login", body: ["email": email, "password": password])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else { return false }
        SessionManager.shared.parentAccessToken = token
        SessionManager.shared.parentRefreshToken = json?["refresh_token"] as? String
        return true
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

    /// A day's screen-time pool — dailyLimitMinutes (or a weekly_schedule
    /// override for that weekday) plus every grant/deduction credited to
    /// it. Defaults to today when `date` is omitted.
    func fetchTimeGrants(childId: String, date: String? = nil) async throws -> ApiTimeGrantsSummary {
        let query = date.map { "?date=\($0)" } ?? ""
        return try decode(try await send("GET", "/children/\(childId)/time-grants\(query)"))
    }

    /// Grants (or, with a negative value, deducts) minutes for today —
    /// what GrantExtraTimeSheet calls now instead of mutating local state.
    @discardableResult
    func createTimeGrant(childId: String, minutes: Int, reason: String? = nil) async throws -> ApiTimeGrant {
        var body: [String: Any] = ["minutes": minutes]
        if let reason { body["reason"] = reason }
        return try decode(try await send("POST", "/children/\(childId)/time-grants", body: body))
    }

    func fetchChatHistory(childId: String) async throws -> [ApiChatMessage] {
        try decode(try await send("GET", "/children/\(childId)/chat"))
    }

    @discardableResult
    func sendChatMessage(childId: String, text: String) async throws -> ApiChatMessage {
        try decode(try await send("POST", "/children/\(childId)/chat", body: ["text": text]))
    }

    // MARK: - Courses

    /// The shared library: vetted courses any of this family's children can
    /// be assigned to, independently of each other.
    func fetchCourses(status: String = "published") async throws -> [ApiCourse] {
        try decode(try await send("GET", "/courses?status=\(status)"))
    }

    func fetchCourse(courseId: String) async throws -> ApiCourse {
        try decode(try await send("GET", "/courses/\(courseId)"))
    }

    /// Searches YouTube and runs the vetting pass. Returns a *draft* —
    /// nothing reaches a child until it's approved.
    func generateCourse(topic: String, videoCount: Int = 4, childId: String? = nil) async throws -> ApiCourse {
        var body: [String: Any] = ["topic": topic, "video_count": videoCount]
        if let childId { body["child_id"] = childId }
        return try decode(try await send("POST", "/courses/generate", body: body))
    }

    /// One specific video the parent picked themselves — published straight
    /// away, since there's no agent judgement to review.
    func createSingleVideoCourse(videoId: String, videoTitle: String?, channelTitle: String?,
                                 quiz: [[String: Any]] = [], title: String? = nil) async throws -> ApiCourse {
        var body: [String: Any] = ["video_id": videoId, "quiz": quiz]
        if let videoTitle { body["video_title"] = videoTitle }
        if let channelTitle { body["channel_title"] = channelTitle }
        if let title { body["title"] = title }
        return try decode(try await send("POST", "/courses/single-video", body: body))
    }

    /// Publishes a drafted course and, when a child is given, assigns it in
    /// the same call.
    @discardableResult
    func approveCourse(courseId: String, assignToChildId: String? = nil) async throws -> ApiCourse {
        var body: [String: Any] = [:]
        if let assignToChildId { body["assign_to_child_id"] = assignToChildId }
        return try decode(try await send("PUT", "/courses/\(courseId)/approve", body: body))
    }

    func searchVideos(query: String) async throws -> [ApiVideoSearchResult] {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try decode(try await send("GET", "/youtube/search?q=\(escaped)"))
    }

    func fetchCourseAssignments(childId: String) async throws -> [ApiCourseAssignment] {
        try decode(try await send("GET", "/children/\(childId)/course-assignments"))
    }

    /// Gives an already-published course to a child — how a sibling gets the
    /// same vetted course with no repeat search.
    @discardableResult
    func assignCourse(childId: String, courseId: String) async throws -> ApiCourseAssignment {
        try decode(try await send("POST", "/children/\(childId)/course-assignments",
                                   body: ["course_id": courseId]))
    }

    /// The kid finishing one video (and its quiz, if it has one). Unlocks
    /// exactly the next item.
    @discardableResult
    func completeCourseItem(progressId: String, quizAnswers: [Int]? = nil) async throws -> ApiCourseItemProgress {
        var body: [String: Any] = [:]
        if let quizAnswers { body["quiz_answers"] = quizAnswers }
        return try decode(try await send("POST", "/course-item-progress/\(progressId)/complete", body: body))
    }

    // MARK: - Reflections

    /// `status: "open"` is the one the gate cares about — pending *or*
    /// awaiting review.
    func fetchReflections(childId: String, status: String? = nil) async throws -> [ApiReflection] {
        let query = status.map { "?status=\($0)" } ?? ""
        return try decode(try await send("GET", "/children/\(childId)/reflections\(query)"))
    }

    /// Give exactly one of videoId (a one-video course is made for it) or
    /// courseId (assign an existing one).
    @discardableResult
    func createReflection(childId: String, videoId: String? = nil, videoTitle: String? = nil,
                          channelTitle: String? = nil, quiz: [[String: Any]] = [],
                          courseId: String? = nil, writtenPrompt: String? = nil) async throws -> ApiReflection {
        var body: [String: Any] = [:]
        if let videoId {
            body["video_id"] = videoId
            body["quiz"] = quiz
            if let videoTitle { body["video_title"] = videoTitle }
            if let channelTitle { body["channel_title"] = channelTitle }
        }
        if let courseId { body["course_id"] = courseId }
        if let writtenPrompt { body["written_prompt"] = writtenPrompt }
        return try decode(try await send("POST", "/children/\(childId)/reflections", body: body))
    }

    @discardableResult
    func submitReflection(reflectionId: String, writtenResponse: String?) async throws -> ApiReflection {
        var body: [String: Any] = [:]
        if let writtenResponse { body["written_response"] = writtenResponse }
        return try decode(try await send("POST", "/reflections/\(reflectionId)/submit", body: body))
    }

    /// `status` is "approved" or "needs_redo".
    @discardableResult
    func reviewReflection(reflectionId: String, status: String, note: String? = nil) async throws -> ApiReflection {
        var body: [String: Any] = ["status": status]
        if let note, !note.isEmpty { body["review_note"] = note }
        return try decode(try await send("PUT", "/reflections/\(reflectionId)/review", body: body))
    }

    // MARK: - Milestones

    func fetchMilestones(childId: String) async throws -> [ApiMilestone] {
        try decode(try await send("GET", "/children/\(childId)/milestones"))
    }

    @discardableResult
    func createMilestone(childId: String, title: String, kind: String, targetCount: Int? = nil,
                         description: String? = nil, prizeText: String? = nil,
                         prizeMinutes: Int = 0, courseId: String? = nil,
                         createdBy: String = "parent") async throws -> ApiMilestone {
        var body: [String: Any] = ["title": title, "kind": kind, "prize_minutes": prizeMinutes,
                                   "created_by": createdBy]
        if let targetCount { body["target_count"] = targetCount }
        if let description { body["description"] = description }
        if let prizeText { body["prize_text"] = prizeText }
        if let courseId { body["course_id"] = courseId }
        return try decode(try await send("POST", "/children/\(childId)/milestones", body: body))
    }

    /// Pays the prize into the time-grant ledger. Only valid once the
    /// milestone's `achievable` is true.
    @discardableResult
    func claimMilestone(milestoneId: String) async throws -> ApiMilestone {
        try decode(try await send("POST", "/milestones/\(milestoneId)/claim"))
    }

    func deleteMilestone(milestoneId: String) async throws {
        _ = try await send("DELETE", "/milestones/\(milestoneId)")
    }

    /// The kid adding something they'd like to work toward. Lands as
    /// "proposed" with no prize — a kid can't write their own screen time,
    /// so a parent decides whether it's real and what it's worth.
    @discardableResult
    func proposeMilestone(childId: String, title: String, description: String? = nil) async throws -> ApiMilestone {
        var body: [String: Any] = ["title": title]
        if let description { body["description"] = description }
        return try decode(try await send("POST", "/children/\(childId)/milestones/propose", body: body))
    }

    /// The parent turning a kid's proposal into a real milestone — this is
    /// where what it takes and what it's worth get decided.
    @discardableResult
    func approveMilestone(milestoneId: String, kind: String? = nil, targetCount: Int? = nil,
                          prizeText: String? = nil, prizeMinutes: Int? = nil) async throws -> ApiMilestone {
        var body: [String: Any] = [:]
        if let kind { body["kind"] = kind }
        if let targetCount { body["target_count"] = targetCount }
        if let prizeText { body["prize_text"] = prizeText }
        if let prizeMinutes { body["prize_minutes"] = prizeMinutes }
        return try decode(try await send("PUT", "/milestones/\(milestoneId)/approve", body: body))
    }

    /// A draft for the parent to edit and then save — creates nothing.
    func generateMilestone(childId: String, hint: String? = nil) async throws -> ApiMilestoneDraft {
        var body: [String: Any] = [:]
        if let hint { body["hint"] = hint }
        return try decode(try await send("POST", "/children/\(childId)/milestones/generate", body: body))
    }

    // MARK: - App blocks

    func fetchAppBlocks(childId: String, activeOnly: Bool = true) async throws -> [ApiAppBlock] {
        try decode(try await send("GET", "/children/\(childId)/app-blocks?active=\(activeOnly)"))
    }

    /// `blockType` is "duration" (needs durationMinutes) or "until_task"
    /// (needs untilTaskId — it lifts itself when that task is approved).
    @discardableResult
    func createAppBlock(childId: String, appName: String, appBundleId: String? = nil,
                        blockType: String, durationMinutes: Int? = nil,
                        untilTaskId: String? = nil) async throws -> ApiAppBlock {
        var body: [String: Any] = ["app_name": appName, "block_type": blockType]
        if let appBundleId { body["app_bundle_id"] = appBundleId }
        if let durationMinutes { body["duration_minutes"] = durationMinutes }
        if let untilTaskId { body["until_task_id"] = untilTaskId }
        return try decode(try await send("POST", "/children/\(childId)/app-blocks", body: body))
    }

    func deleteAppBlock(blockId: String) async throws {
        _ = try await send("DELETE", "/app-blocks/\(blockId)")
    }

    // MARK: - Task Management (Bi-directional Sync)

    /// Creates the task on the backend and returns the saved row, so callers
    /// can use the real database id instead of a locally generated one.
    /// `courseId` makes this a special task: the course is assigned to the
    /// child and the task is completed by finishing it. A course still
    /// awaiting review is published by this same call — creating the task
    /// *is* the approval, so there's never a task pointing at an unpublished
    /// course. Pair it with `bonusMinutes` for "watch this, earn screen time".
    func createTask(childId: String, title: String, instructions: String?, recurrence: String, category: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil, bonusMinutes: Int = 0, courseId: String? = nil, milestoneId: String? = nil, createdBy: String = "parent") async throws -> ApiTask {
        var body: [String: Any] = [
            "title": title,
            "instructions": instructions ?? "",
            "recurrence": recurrence,
            "category": category,
            "submission_kind": submissionKind,
            "bonus_minutes": bonusMinutes,
            "created_by": createdBy
        ]
        if let dueTime { body["due_time"] = dueTime }
        if let dueDate { body["due_date"] = dueDate }
        if let courseId { body["course_id"] = courseId }
        if let milestoneId { body["milestone_id"] = milestoneId }
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
