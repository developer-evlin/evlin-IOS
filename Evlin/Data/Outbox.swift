import Foundation
import Network

/// One write to the server, kept as the exact request to send, so it can wait
/// in the outbox across launches and go out later unchanged.
struct WriteRequest: Codable {
    var method: String
    var path: String
    var body: Data?
    /// Set for a kid's write against an occurrence this phone made up
    /// offline (LocalStore.materializeTodayIfNeeded): the server has never
    /// seen its id, so the real one is looked up by task and day when sent.
    var occurrence: OccurrenceRef?

    struct OccurrenceRef: Codable {
        var localId: String
        var childId: String
        var taskId: String
        var dueDate: String
    }

    init(_ method: String, _ path: String, body: [String: Any]? = nil) {
        self.method = method
        self.path = path
        self.body = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }
}

extension APIClient {
    /// Every write the app makes, built once here. `APIClient` sends these
    /// straight away; the outbox saves them and sends them in order.
    enum Write {
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()

        /// A new id for a row made on the phone, in the server's spelling.
        static func newId() -> String { UUID().uuidString.lowercased() }

        static func updateMyName(_ name: String) -> WriteRequest {
            WriteRequest("PUT", "/auth/me", body: ["name": name])
        }

        static func updateChild(childId: String, name: String? = nil, colorIndex: Int? = nil) -> WriteRequest {
            var body: [String: Any] = [:]
            if let name { body["name"] = name }
            if let colorIndex { body["color_index"] = colorIndex }
            return WriteRequest("PUT", "/children/\(childId)", body: body)
        }

        static func deleteChild(childId: String) -> WriteRequest {
            WriteRequest("DELETE", "/children/\(childId)")
        }

        /// Ends the kid device's token; that phone goes back to the start.
        static func unpairDevice(childId: String) -> WriteRequest {
            WriteRequest("DELETE", "/children/\(childId)/device")
        }

        // MARK: Calendar

        private static func eventBody(childId: String, title: String, start: Date, end: Date, category: String?,
                                      note: String?, location: String?, recurrence: String) -> [String: Any] {
            var body: [String: Any] = [
                "child_id": childId,
                "title": title,
                "start_at": iso.string(from: start),
                "end_at": iso.string(from: end),
                "recurrence": recurrence,
            ]
            if let category { body["category"] = category }
            if let note { body["note"] = note }
            if let location, !location.isEmpty { body["location_or_link"] = location }
            return body
        }

        static func createEvent(id: String, childId: String, title: String, start: Date, end: Date, category: String?,
                                note: String?, location: String?, recurrence: String) -> WriteRequest {
            var body = eventBody(childId: childId, title: title, start: start, end: end, category: category,
                                 note: note, location: location, recurrence: recurrence)
            body["id"] = id
            return WriteRequest("POST", "/events", body: body)
        }

        static func updateEvent(eventId: String, childId: String, title: String, start: Date, end: Date, category: String?,
                                note: String?, location: String?, recurrence: String) -> WriteRequest {
            WriteRequest("PUT", "/events/\(eventId)", body: eventBody(
                childId: childId, title: title, start: start, end: end, category: category,
                note: note, location: location, recurrence: recurrence))
        }

        static func deleteEvent(eventId: String) -> WriteRequest {
            WriteRequest("DELETE", "/events/\(eventId)")
        }

        private static func planBody(title: String, start: Date, end: Date, note: String?, location: String?) -> [String: Any] {
            var body: [String: Any] = [
                "title": title,
                "start_at": iso.string(from: start),
                "end_at": iso.string(from: end),
            ]
            if let note, !note.isEmpty { body["note"] = note }
            if let location, !location.isEmpty { body["location_or_link"] = location }
            return body
        }

        /// Kid device: a plan for its own calendar, waiting on the parent.
        static func createPlan(id: String, title: String, start: Date, end: Date, note: String?, location: String?) -> WriteRequest {
            var body = planBody(title: title, start: start, end: end, note: note, location: location)
            body["id"] = id
            return WriteRequest("POST", "/device/plans", body: body)
        }

        static func updatePlan(eventId: String, title: String, start: Date, end: Date, note: String?, location: String?) -> WriteRequest {
            WriteRequest("PUT", "/device/plans/\(eventId)", body: planBody(title: title, start: start, end: end, note: note, location: location))
        }

        /// Withdraws a waiting plan, or dismisses a declined one.
        static func deletePlan(eventId: String) -> WriteRequest {
            WriteRequest("DELETE", "/device/plans/\(eventId)")
        }

        static func approvePlan(eventId: String) -> WriteRequest {
            WriteRequest("POST", "/events/\(eventId)/approve")
        }

        static func declinePlan(eventId: String, note: String?) -> WriteRequest {
            WriteRequest("POST", "/events/\(eventId)/decline", body: ["note": note ?? ""])
        }

        // MARK: Tasks

        static func createTask(id: String, childId: String, title: String, instructions: String?, recurrence: String,
                               category: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil,
                               bonusMinutes: Int = 0, createdBy: String = "parent") -> WriteRequest {
            var body: [String: Any] = [
                "id": id,
                "title": title,
                "instructions": instructions ?? "",
                "recurrence": recurrence,
                "category": category,
                "submission_kind": submissionKind,
                "bonus_minutes": bonusMinutes,
                "created_by": createdBy,
            ]
            if let dueTime { body["due_time"] = dueTime }
            if let dueDate {
                body["due_date"] = dueDate
            } else if recurrence.isEmpty || recurrence == "none" {
                // A one-off with no day is for today: the phone's today,
                // stamped now. Left out, the server picks the day from its
                // own clock, and only knows the family's time zone once a
                // kid's device has reported it.
                body["due_date"] = CalendarSync.isoDay(Date())
            }
            return WriteRequest("POST", "/children/\(childId)/tasks", body: body)
        }

        /// A nil `dueTime` leaves the time as it is; `clearDueTime` removes it
        /// (sent as an explicit null, which the server reads as "no time").
        static func updateTask(taskId: String, title: String, instructions: String?, recurrence: String, category: String,
                               submissionKind: String, dueTime: String? = nil, dueDate: String? = nil,
                               clearDueTime: Bool = false) -> WriteRequest {
            var body: [String: Any] = [
                "title": title,
                "instructions": instructions ?? "",
                "recurrence": recurrence,
                "category": category,
                "submission_kind": submissionKind,
            ]
            if let dueTime { body["due_time"] = dueTime } else if clearDueTime { body["due_time"] = NSNull() }
            if let dueDate { body["due_date"] = dueDate }
            return WriteRequest("PUT", "/tasks/\(taskId)", body: body)
        }

        static func deleteTask(taskId: String) -> WriteRequest {
            WriteRequest("DELETE", "/tasks/\(taskId)")
        }

        static func submitTask(occurrenceId: String, bypassNote: String? = nil) -> WriteRequest {
            var body: [String: Any] = [:]
            if let bypassNote { body["bypass_note"] = bypassNote }
            return WriteRequest("POST", "/tasks/occurrences/\(occurrenceId)/submit", body: body)
        }

        static func approveTask(occurrenceId: String) -> WriteRequest {
            WriteRequest("POST", "/tasks/occurrences/\(occurrenceId)/approve")
        }

        /// Parent asks for a redo; the note is shown to the kid.
        static func rejectTask(occurrenceId: String, note: String?) -> WriteRequest {
            var body: [String: Any] = ["status": "rejected"]
            if let note, !note.isEmpty { body["rejection_note"] = note }
            return WriteRequest("PUT", "/occurrences/\(occurrenceId)/status", body: body)
        }

        /// Kid asks to skip a task today.
        static func requestBypass(occurrenceId: String, note: String?) -> WriteRequest {
            WriteRequest("POST", "/occurrences/\(occurrenceId)/bypass", body: ["bypass_note": note ?? ""])
        }

        // MARK: Rules, state, time

        /// The whole rules picture for a child (see `RuleSync.payload`).
        static func saveRules(childId: String, body: [String: Any]) -> WriteRequest {
            WriteRequest("PUT", "/children/\(childId)/rules", body: body)
        }

        static func updateChildState(childId: String, manualLock: Bool, taskGateOverride: Bool) -> WriteRequest {
            WriteRequest("PUT", "/children/\(childId)/state", body: [
                "manual_lock": manualLock,
                "task_gate_override": taskGateOverride,
            ])
        }

        /// Grants (or, with a negative value, deducts) minutes for today.
        static func createTimeGrant(childId: String, minutes: Int, reason: String? = nil) -> WriteRequest {
            var body: [String: Any] = ["minutes": minutes]
            if let reason { body["reason"] = reason }
            return WriteRequest("POST", "/children/\(childId)/time-grants", body: body)
        }

        /// Ends a block early. Kept server-side as history, not deleted.
        static func liftAppBlock(blockId: String) -> WriteRequest {
            WriteRequest("POST", "/app-blocks/\(blockId)/lift")
        }
    }
}

/// Every change a parent or kid makes goes out through here.
///
/// The screen has already shown the change. The write is saved on the phone
/// (a `PendingWrite` row) before anything is sent, then sent oldest first, so
/// a create always reaches the server before an edit of the same thing. A
/// write that can't go yet (offline, or the server is struggling) stays
/// first in line and is retried with backoff, when the network comes back,
/// and on every sync; a closed app picks it up on the next launch.
///
/// A sync sends the outbox before fetching and doesn't fetch while anything
/// is still waiting, so the server's older picture never replaces a change
/// that hasn't reached it yet.
@MainActor
enum Outbox {
    private static var draining: Task<DrainResult, Never>?
    private static var retry: Task<Void, Never>?
    private static var pathMonitor: NWPathMonitor?
    // Backoff for writes that can't go yet; back to the start once one goes.
    private static var failedTries = 0

    /// Goes up with every write queued. A sync that sees it move while
    /// fetching knows its answer may predate that write (AppSync).
    private(set) static var generation = 0

    struct DrainResult {
        /// Nothing is left waiting.
        var isEmpty: Bool
        /// A write was dropped (refused, or already done), so what the
        /// screen shows may be ahead of the server.
        var droppedAny: Bool
    }

    /// Saves a write and starts sending it. `label` names it in an error
    /// ("Approving the task wasn't saved").
    static func send(_ request: WriteRequest, childId: String? = nil, label: String) {
        LocalStore.shared.queueWrite(PendingWrite(request: request, childId: childId ?? "", label: label))
        generation += 1
        Task {
            // Dropped writes leave the screen showing something the server
            // doesn't have, so fetch the truth back.
            if await drain().droppedAny { await AppSync.shared.syncBackendData() }
        }
    }

    /// Sends a kid's write against one of today's occurrences, naming the
    /// task and day too when the occurrence was made up on this phone.
    static func send(_ request: WriteRequest, occurrenceId: String, taskId: String, childId: String, label: String) {
        var request = request
        if let local = LocalStore.shared.localOccurrence(id: occurrenceId) {
            request.occurrence = .init(localId: occurrenceId, childId: childId, taskId: taskId, dueDate: local.dueDate)
        }
        send(request, childId: childId, label: label)
    }

    static var hasPending: Bool { !LocalStore.shared.pendingRequests().isEmpty }

    /// Sends what's waiting, oldest first, until the outbox is empty or a
    /// write has to wait. Callers arriving mid-drain share the same pass.
    @discardableResult
    static func drain() async -> DrainResult {
        // The debug demo keeps its writes on the phone (DemoMode).
        if DemoMode.isOn { return DrainResult(isEmpty: true, droppedAny: false) }
        if let draining { return await draining.value }
        let task = Task { await run() }
        draining = task
        let result = await task.value
        draining = nil
        return result
    }

    /// Watches for the network coming back, which is when a waiting write
    /// can go.
    static func startWatchingNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard hasPending else { return }
                await AppSync.shared.syncBackendData()
            }
        }
        monitor.start(queue: DispatchQueue(label: "evlin.outbox.network"))
        pathMonitor = monitor
    }

    /// Signing out: nothing queued under the old account may be sent.
    static func discardAll() {
        retry?.cancel()
        retry = nil
        LocalStore.shared.removeAllPendingRequests()
    }

    // A server error repeated this many times is taken to be about the
    // write itself, not a bad moment, and the write is dropped so it stops
    // holding up the ones behind it. Not being online never counts.
    private static let maxServerErrors = 6

    // FastAPI's answer for a path it has no route for, as opposed to the
    // app's own 404s ("Event not found"): the server is older than the app.
    private static let noSuchRoute = "Not Found"

    private static func run() async -> DrainResult {
        var droppedAny = false
        while let write = LocalStore.shared.pendingRequests().first {
            guard let request = write.request else {
                LocalStore.shared.removePendingWrite(write)
                continue
            }
            let label = write.label ?? "That change"
            do {
                try await APIClient.shared.send(try await resolve(request))
                LocalStore.shared.removePendingWrite(write)
                failedTries = 0
            } catch let failure as APIFailure where (failure.status == 404 && failure.detail != Self.noSuchRoute) || failure.status == 409 {
                // Gone, or already that way: a retry whose first try got
                // through but whose answer was lost, or a change someone
                // else already made. Nothing to send any more. (A 404 for
                // a route the server doesn't have is a real failure, and
                // falls through to be reported.)
                print("Outbox: \(request.method) \(request.path) answered \(failure.status); dropped")
                LocalStore.shared.removePendingWrite(write)
                droppedAny = true
            } catch let failure as APIFailure where (400..<500).contains(failure.status) && ![401, 408, 429].contains(failure.status) {
                SyncState.shared.writeError = "\(label) wasn't saved. \(failure.apiUserMessage)"
                LocalStore.shared.removePendingWrite(write)
                droppedAny = true
            } catch {
                let serverError = (error as? APIFailure).map { $0.status >= 500 } ?? false
                if serverError { write.attempts += 1 }
                if serverError && write.attempts >= maxServerErrors {
                    SyncState.shared.writeError = "\(label) wasn't saved. \(error.apiUserMessage)"
                    LocalStore.shared.removePendingWrite(write)
                    droppedAny = true
                    continue
                }
                LocalStore.shared.saveChanges()
                failedTries += 1
                scheduleRetry(after: failedTries)
                return DrainResult(isEmpty: false, droppedAny: droppedAny)
            }
        }
        return DrainResult(isEmpty: true, droppedAny: droppedAny)
    }

    /// Swaps an occurrence id made up on this phone for the server's real
    /// one, found by task and day.
    private static func resolve(_ request: WriteRequest) async throws -> WriteRequest {
        guard let ref = request.occurrence else { return request }
        let realId: String
        if let known = LocalStore.shared.serverOccurrenceId(childId: ref.childId, taskId: ref.taskId, dueDate: ref.dueDate) {
            realId = known
        } else {
            let occurrences = try await APIClient.shared.fetchOccurrences(childId: ref.childId, dueDate: ref.dueDate)
            guard let match = occurrences.first(where: { $0.taskId == ref.taskId }) else {
                throw APIFailure(status: 404, detail: "That task isn't on \(ref.dueDate) any more")
            }
            realId = match.id
        }
        var resolved = request
        resolved.path = request.path.replacingOccurrences(of: ref.localId, with: realId)
        resolved.occurrence = nil
        return resolved
    }

    /// 2, 4, 8 … seconds, up to a minute, while the app is open. (Coming
    /// back online retries at once: see startWatchingNetwork.)
    private static func scheduleRetry(after attempts: Int) {
        retry?.cancel()
        let seconds = min(60, 1 << min(max(attempts, 1), 6))
        retry = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await AppSync.shared.syncBackendData()
        }
    }
}
