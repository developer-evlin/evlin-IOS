import Foundation
import Sentry
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
    /// A kid's Send: the photos it names. It waits in the outbox until
    /// they're uploaded (PhotoUploads.holds).
    var photoIds: [String]?

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

        /// The kid's device names its child, after pairing.
        static func nameMyChild(_ name: String) -> WriteRequest {
            WriteRequest("PUT", "/device/me", body: ["name": name])
        }

        /// Family Sharing's hand-off (`FamilySharingHandOff`): the kid's
        /// device's stage; "" clears it.
        static func mySetupStage(_ stage: String) -> WriteRequest {
            WriteRequest("PUT", "/device/me", body: ["setup_stage": stage])
        }

        /// "I've created the account", tapped on the parent's phone: the
        /// kid's device on the account steps moves on (`FamilySharingHandOff`).
        static func childAccountCreated(_ childId: String) -> WriteRequest {
            WriteRequest("PUT", "/children/\(childId)/setup-stage", body: ["setup_stage": "account_created"])
        }

        static func updateMyName(_ name: String) -> WriteRequest {
            WriteRequest("PUT", "/auth/me", body: ["name": name])
        }

        /// `activeGoal`: the Library's goal; an empty string clears it.
        static func updateChild(childId: String, name: String? = nil, colorIndex: Int? = nil,
                                activeGoal: String? = nil) -> WriteRequest {
            var body: [String: Any] = [:]
            if let name { body["name"] = name }
            if let colorIndex { body["color_index"] = colorIndex }
            if let activeGoal { body["active_goal"] = activeGoal }
            return WriteRequest("PUT", "/children/\(childId)", body: body)
        }

        static func deleteChild(childId: String) -> WriteRequest {
            WriteRequest("DELETE", "/children/\(childId)")
        }

        /// Ends the kid device's token; that phone goes back to the start.
        static func unpairDevice(childId: String) -> WriteRequest {
            WriteRequest("DELETE", "/children/\(childId)/device")
        }

        // MARK: Tasks

        static func createTask(id: String, childId: String, title: String, instructions: String?, recurrence: String,
                               category: String, submissionKind: String, dueTime: String? = nil, dueDate: String? = nil,
                               bonusMinutes: Int = 0, createdBy: String = "parent", icon: String? = nil) -> WriteRequest {
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
            if let icon { body["icon"] = icon }
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
                               clearDueTime: Bool = false, icon: String? = nil) -> WriteRequest {
            var body: [String: Any] = [
                "title": title,
                "instructions": instructions ?? "",
                "recurrence": recurrence,
                "category": category,
                "submission_kind": submissionKind,
            ]
            if let dueTime { body["due_time"] = dueTime } else if clearDueTime { body["due_time"] = NSNull() }
            if let dueDate { body["due_date"] = dueDate }
            if let icon { body["icon"] = icon }
            return WriteRequest("PUT", "/tasks/\(taskId)", body: body)
        }

        static func deleteTask(taskId: String) -> WriteRequest {
            WriteRequest("DELETE", "/tasks/\(taskId)")
        }

        /// A repeating task deleted for one day ("This task": `through` the
        /// same day) or from a day on ("This and following tasks": `through`
        /// nil), days as "YYYY-MM-DD". The server takes those days off,
        /// whatever was done on them (routers/tasks.py `cut_task`).
        static func cutTask(taskId: String, from: String, through: String?) -> WriteRequest {
            var body: [String: Any] = ["from": from]
            if let through { body["through"] = through }
            return WriteRequest("POST", "/tasks/\(taskId)/cut", body: body)
        }

        /// The same days edited instead: `newTask` (a `createTask`, its id
        /// made on the phone) takes them, with whatever was sent in or
        /// approved on them, and the series keeps the rest
        /// (routers/tasks.py `split_task`).
        static func splitTask(taskId: String, from: String, through: String?, newTask: WriteRequest) -> WriteRequest {
            var body: [String: Any] = ["from": from]
            if let through { body["through"] = through }
            body["task"] = newTask.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            return WriteRequest("POST", "/tasks/\(taskId)/split", body: body)
        }

        /// The kid's Send. `photoIds`: the photos sent in with it, each
        /// checked in R2 by the server before it counts (PhotoUploads).
        static func submitTask(occurrenceId: String, bypassNote: String? = nil, photoIds: [String]? = nil) -> WriteRequest {
            var body: [String: Any] = [:]
            if let bypassNote { body["bypass_note"] = bypassNote }
            if let photoIds { body["photo_ids"] = photoIds }
            var request = WriteRequest("POST", "/tasks/occurrences/\(occurrenceId)/submit", body: body)
            request.photoIds = photoIds
            return request
        }

        /// A place on the server for one photo, named by the phone, and a
        /// link to upload it to R2, signed for its exact size.
        static func photoSlot(occurrenceId: String, photoId: String, contentType: String, bytes: Int) -> WriteRequest {
            WriteRequest("POST", "/occurrences/\(occurrenceId)/submissions", body: [
                "id": photoId, "kind": "photo", "content_type": contentType, "bytes_size": bytes,
            ])
        }

        static func approveTask(occurrenceId: String) -> WriteRequest {
            WriteRequest("POST", "/tasks/occurrences/\(occurrenceId)/approve")
        }

        /// Parent takes an approval back: the task returns to how it was
        /// (waiting for review if it was sent in, else to do).
        static func unapproveTask(occurrenceId: String) -> WriteRequest {
            WriteRequest("POST", "/tasks/occurrences/\(occurrenceId)/unapprove")
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

        static func updateChildState(childId: String, manualLock: Bool, taskGateOverride: Bool, instantUnlock: Bool) -> WriteRequest {
            WriteRequest("PUT", "/children/\(childId)/state", body: [
                "manual_lock": manualLock,
                "task_gate_override": taskGateOverride,
                "instant_unlock": instantUnlock,
            ])
        }

        /// Grants (or, with a negative value, deducts) minutes for today.
        static func createTimeGrant(childId: String, minutes: Int, reason: String? = nil) -> WriteRequest {
            var body: [String: Any] = ["minutes": minutes]
            if let reason { body["reason"] = reason }
            return WriteRequest("POST", "/children/\(childId)/time-grants", body: body)
        }

        /// Blocks apps for a set time (`durationMinutes`) or until the
        /// parent lifts it (nil). Apps not on the child's list yet are added.
        static func createAppBlocks(childId: String, appIds: [String], durationMinutes: Int?) -> WriteRequest {
            var body: [String: Any] = ["app_ids": appIds, "add_to_list": true,
                                       "block_type": durationMinutes == nil ? "indefinite" : "duration"]
            if let durationMinutes { body["duration_minutes"] = durationMinutes }
            return WriteRequest("POST", "/children/\(childId)/app-blocks", body: body)
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
        /// All that's left is a Send waiting for its photos to upload:
        /// not a connection problem, just a moment.
        var waitingOnPhotos: Bool = false
    }

    /// Saves a write and starts sending it. `label` names it in an error
    /// ("Approving the task wasn't saved").
    @discardableResult
    static func send(_ request: WriteRequest, childId: String? = nil, label: String) -> String {
        let write = PendingWrite(request: request, childId: childId ?? "", label: label)
        LocalStore.shared.queueWrite(write)
        generation += 1
        Task {
            // Dropped writes leave the screen showing something the server
            // doesn't have, so fetch the truth back.
            if await drain().droppedAny { await AppSync.shared.syncBackendData() }
        }
        return write.id
    }

    /// Sends a kid's write against one of today's occurrences, naming the
    /// task and day too when the occurrence was made up on this phone.
    @discardableResult
    static func send(_ request: WriteRequest, occurrenceId: String, taskId: String, childId: String, label: String) -> String {
        var request = request
        if let local = LocalStore.shared.localOccurrence(id: occurrenceId) {
            request.occurrence = .init(localId: occurrenceId, childId: childId, taskId: taskId, dueDate: local.dueDate)
        }
        return send(request, childId: childId, label: label)
    }

    static var hasPending: Bool { !LocalStore.shared.pendingRequests().isEmpty || PhotoUploads.shared.hasWork }

    /// How a write ended, by its id, for a screen waiting on one (the
    /// kid's Send): true sent, false dropped. Kept for this launch only.
    private static var outcomes: [String: Bool] = [:]

    enum Arrival { case sent, refused, notYet }

    /// Waits up to `seconds` for one write to reach the server.
    static func waitUntilSent(_ writeId: String, seconds: Double) async -> Arrival {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let sent = outcomes[writeId] { return sent ? .sent : .refused }
            if LocalStore.shared.pendingWrite(id: writeId) == nil { return .sent }
            if Date() >= deadline { return .notYet }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Sends what's waiting, oldest first, until the outbox is empty or a
    /// write has to wait. Callers arriving mid-drain share the same pass.
    @discardableResult
    static func drain() async -> DrainResult {
        // The Demo build keeps its writes on the phone (DemoMode).
        if DemoMode.isBuild { return DrainResult(isEmpty: true, droppedAny: false) }
        // A kid's photos go first, alongside: a Send waits for its own.
        PhotoUploads.shared.run()
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

    /// How long a write the server has no route for yet waits before it's
    /// tried again (the app can reach phones before its server is deployed).
    private static let parkFor: TimeInterval = 15 * 60

    /// A write that can't go through, told to us and never to the parent: a
    /// raw server message on their screen only alarms them, and the next
    /// sync puts the screen back as the server has it. Debug builds still
    /// show it, so a problem is seen while testing.
    private static func reportUnsaved(_ text: String) {
        #if DEBUG
        SyncState.shared.writeError = text
        #else
        SentrySDK.capture(message: text)
        #endif
    }

    private static func isParked(_ write: PendingWrite) -> Bool {
        (write.parkedUntil ?? .distantPast) > Date()
    }

    private static func run() async -> DrainResult {
        var droppedAny = false
        while let write = LocalStore.shared.pendingRequests().first(where: {
            !isParked($0) && !($0.request.map(PhotoUploads.shared.holds) ?? false)
        }) {
            guard let request = write.request else {
                LocalStore.shared.removePendingWrite(write)
                continue
            }
            let label = write.label ?? "That change"
            let writeId = write.id, childId = write.childId
            do {
                let sent = try await resolve(request)
                let answer = try await APIClient.shared.send(sent)
                LocalStore.shared.removePendingWrite(write)
                outcomes[writeId] = true
                adoptServerId(sent: sent, answer: answer)
                PhotoUploads.shared.sendAccepted(sent, answer: answer, childId: childId, label: label)
                failedTries = 0
                ConnectionStatus.shared.setServerTrouble(false)
            } catch let failure as APIFailure where failure.status == 404 && failure.detail == Self.noSuchRoute {
                // The server is older than this app and has no such route
                // yet. Kept, not dropped, and set aside so the writes behind
                // it still go: it goes through once the server has the route.
                if write.parkedUntil == nil {
                    SentrySDK.capture(message: "Outbox: server has no route for \(request.method) \(request.path); kept for later")
                }
                write.parkedUntil = Date().addingTimeInterval(Self.parkFor)
                LocalStore.shared.saveChanges()
            } catch let failure as APIFailure where (failure.status == 404 && failure.detail != Self.noSuchRoute) || failure.status == 409 {
                // Gone, or already that way: a retry whose first try got
                // through but whose answer was lost, or a change someone
                // else already made. Nothing to send any more.
                print("Outbox: \(request.method) \(request.path) answered \(failure.status); dropped")
                LocalStore.shared.removePendingWrite(write)
                outcomes[writeId] = false
                droppedAny = true
            } catch let failure as APIFailure where (400..<500).contains(failure.status) && ![401, 408, 429].contains(failure.status) {
                reportUnsaved("\(label) wasn't saved. \(failure.apiUserMessage)")
                LocalStore.shared.removePendingWrite(write)
                outcomes[writeId] = false
                droppedAny = true
            } catch {
                let serverError = (error as? APIFailure).map { $0.status >= 500 } ?? false
                if serverError { write.attempts += 1 }
                if serverError && write.attempts >= maxServerErrors {
                    reportUnsaved("\(label) wasn't saved. \(error.apiUserMessage)")
                    LocalStore.shared.removePendingWrite(write)
                    outcomes[writeId] = false
                    droppedAny = true
                    continue
                }
                LocalStore.shared.saveChanges()
                failedTries += 1
                // Not reaching the server (offline shows as offline; this is
                // the server slow, waking, or down): the pill says so.
                ConnectionStatus.shared.setServerTrouble(true)
                scheduleRetry(after: failedTries)
                return DrainResult(isEmpty: false, droppedAny: droppedAny)
            }
        }
        // What's left waits for photos still uploading (PhotoUploads.holds).
        let held = LocalStore.shared.pendingRequests().filter { !isParked($0) }
        return DrainResult(isEmpty: held.isEmpty, droppedAny: droppedAny, waitingOnPhotos: !held.isEmpty)
    }

    /// A create carries the phone's id. A server that answers with another
    /// id (one too old to take it) made the row under that id: the phone's
    /// copy takes it, rather than the next sync deleting the phone's row and
    /// adding the server's as a new one.
    private static func adoptServerId(sent: WriteRequest, answer: Data) {
        guard sent.method == "POST",
              let body = sent.body.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let localId = body["id"] as? String,
              let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let serverId = reply["id"] as? String,
              serverId.lowercased() != localId.lowercased() else { return }
        print("Outbox: \(sent.path) made \(serverId) for the phone's \(localId); adopting the server's id")
        LocalStore.shared.adoptServerId(serverId, for: localId)
    }

    /// Swaps an occurrence id made up on this phone for the server's real
    /// one, found by task and day.
    static func resolve(_ request: WriteRequest) async throws -> WriteRequest {
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
