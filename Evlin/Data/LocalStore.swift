import Foundation
import SwiftData

// The phone's database, on both the parent's and the kid's phone (see
// "Phone database" in CLAUDE.md). It keeps the server's own rows: every
// child with their rules and state, their tasks, today's occurrences, time
// grants, app blocks, policy and calendar events, plus the outbox of writes
// not sent yet. Launch builds the screens from it before the network
// answers; every sync writes through to it, merging by id.
//
// Everything here is keyed by childId, matching TaskStore's existing
// keying (Evlin/Data/TaskData.swift).

@Model
final class CachedTask {
    @Attribute(.unique) var id: String
    var childId: String
    var title: String
    var instructions: String?
    var category: String?
    var recurrence: String
    var gatesApps: Bool
    var submissionKind: String
    var dueDate: String?   // "YYYY-MM-DD"
    var dueTime: String?   // "HH:MM:SS"
    var active: Bool
    var bonusMinutes: Int
    var createdBy: String
    var createdAt: String?

    init(id: String, childId: String, title: String, instructions: String?, category: String?,
         recurrence: String, gatesApps: Bool, submissionKind: String, dueDate: String?, dueTime: String?,
         active: Bool, bonusMinutes: Int, createdBy: String, createdAt: String?) {
        self.id = id; self.childId = childId; self.title = title; self.instructions = instructions
        self.category = category; self.recurrence = recurrence; self.gatesApps = gatesApps
        self.submissionKind = submissionKind; self.dueDate = dueDate; self.dueTime = dueTime
        self.active = active; self.bonusMinutes = bonusMinutes; self.createdBy = createdBy
        self.createdAt = createdAt
    }

    convenience init(_ api: ApiTask, childId: String) {
        self.init(id: api.id, childId: childId, title: api.title, instructions: api.instructions,
                   category: api.category, recurrence: api.recurrence, gatesApps: api.gatesApps,
                   submissionKind: api.submissionKind, dueDate: api.dueDate, dueTime: api.dueTime,
                   active: true, bonusMinutes: api.bonusMinutes, createdBy: api.createdBy, createdAt: api.createdAt)
    }

    func apiShape() -> ApiTask {
        ApiTask(id: id, title: title, instructions: instructions, recurrence: recurrence, gatesApps: gatesApps,
                submissionKind: submissionKind, bucket: "anytime", category: category, dueDate: dueDate,
                dueTime: dueTime, createdAt: createdAt, bonusMinutes: bonusMinutes, createdBy: createdBy)
    }
}

@Model
final class CachedOccurrence {
    @Attribute(.unique) var id: String
    var taskId: String
    var childId: String
    var dueDate: String
    var status: String
    var bypassRequested: Bool
    var bypassNote: String?
    var rejectionNote: String?
    // True for a row this device materialized itself (see
    // LocalStore.materializeTodayIfNeeded) rather than one confirmed by a
    // real sync — lets the next successful sync's authoritative list
    // safely replace it instead of accumulating a duplicate.
    var isLocallyMaterialized: Bool
    // Today's photo links, so the review card has its photos at launch. The
    // links themselves expire within the hour, but ImageCache finds an
    // already-downloaded photo by its path alone.
    var photoURLsJSON: Data?
    /// When those links were signed (they last an hour).
    var photoURLsSavedAt: Date?

    var photoURLs: [String] {
        get { photoURLsJSON.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { photoURLsJSON = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(id: String, taskId: String, childId: String, dueDate: String, status: String,
         bypassRequested: Bool, bypassNote: String?, rejectionNote: String?, isLocallyMaterialized: Bool) {
        self.id = id; self.taskId = taskId; self.childId = childId; self.dueDate = dueDate
        self.status = status; self.bypassRequested = bypassRequested; self.bypassNote = bypassNote
        self.rejectionNote = rejectionNote; self.isLocallyMaterialized = isLocallyMaterialized
    }

    // The server may send the day as a timestamp ("2026-10-10T00:00:00");
    // it's kept as the plain day, the way every lookup here asks for it.
    convenience init(_ api: ApiOccurrence) {
        self.init(id: api.id, taskId: api.taskId, childId: api.childId, dueDate: String(api.dueDate.prefix(10)), status: api.status,
                   bypassRequested: api.bypassRequested, bypassNote: api.bypassNote, rejectionNote: api.rejectionNote,
                   isLocallyMaterialized: false)
    }

    /// Takes newly signed links, unless they're for the same photos as the
    /// links already here and those still have most of their hour left.
    /// Every sync signs every link afresh; swapping them in each time made
    /// the task list count as changed and redraw every few seconds.
    func keepPhotoLinks(_ urls: [String]) {
        func paths(_ list: [String]) -> [String] { list.map { $0.split(separator: "?").first.map(String.init) ?? $0 } }
        let fresh = photoURLsSavedAt.map { Date().timeIntervalSince($0) < 40 * 60 } ?? false
        if fresh && paths(urls) == paths(photoURLs) { return }
        photoURLs = urls
        photoURLsSavedAt = urls.isEmpty ? nil : Date()
    }

    var apiShape: ApiOccurrence {
        ApiOccurrence(id: id, taskId: taskId, childId: childId, dueDate: dueDate, status: status,
                      bypassRequested: bypassRequested, bypassNote: bypassNote, rejectionNote: rejectionNote)
    }
}

@Model
final class CachedTimeGrant {
    @Attribute(.unique) var id: String
    var childId: String
    var minutes: Int   // signed — a deduction is negative
    var source: String
    var reason: String?
    var createdBy: String
    var creditedDate: String
    var createdAt: String

    init(id: String, childId: String, minutes: Int, source: String, reason: String?, createdBy: String,
         creditedDate: String, createdAt: String) {
        self.id = id; self.childId = childId; self.minutes = minutes; self.source = source
        self.reason = reason; self.createdBy = createdBy; self.creditedDate = creditedDate; self.createdAt = createdAt
    }

    convenience init(_ api: ApiTimeGrant) {
        self.init(id: api.id, childId: api.childId, minutes: api.minutes, source: api.source, reason: api.reason,
                   createdBy: api.createdBy, creditedDate: api.creditedDate, createdAt: api.createdAt)
    }
}

@Model
final class CachedChildState {
    @Attribute(.unique) var childId: String
    var childName: String
    var dailyLimitMinutes: Int
    // JSON-encoded [String: Int]? ({"mon": 120, ...}) — stored as a string
    // rather than a native dictionary so this doesn't depend on SwiftData's
    // dictionary-attribute support; decoded on read (see weeklySchedule).
    var weeklyScheduleJSON: String?
    var downtimeEnabled: Bool
    var downtimeStart: String?
    var downtimeEnd: String?
    var manualLock: Bool
    var taskGateOverride: Bool
    // The server's own rows for this child, so launch can build the child
    // exactly the way a sync does (AppSync.makeChild). Optional: rows saved
    // before these existed fill in on the next sync.
    var childJSON: Data?
    var rulesJSON: Data?
    /// Where the child comes in the family's order.
    var position: Int?
    /// Today's real total (base or weekly-schedule limit plus grants), and
    /// the day it's for.
    var availableMinutes: Int?
    var availableOn: String?

    var apiChild: ApiChild? { childJSON.flatMap { try? JSONDecoder().decode(ApiChild.self, from: $0) } }
    var rules: ApiChildRule? { rulesJSON.flatMap { try? JSONDecoder().decode(ApiChildRule.self, from: $0) } }

    var weeklySchedule: [String: Int]? {
        get {
            guard let json = weeklyScheduleJSON, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: Int].self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                weeklyScheduleJSON = nil
                return
            }
            weeklyScheduleJSON = String(data: data, encoding: .utf8)
        }
    }

    init(childId: String, childName: String, dailyLimitMinutes: Int, weeklyScheduleJSON: String?, downtimeEnabled: Bool,
         downtimeStart: String?, downtimeEnd: String?, manualLock: Bool, taskGateOverride: Bool) {
        self.childId = childId; self.childName = childName; self.dailyLimitMinutes = dailyLimitMinutes
        self.weeklyScheduleJSON = weeklyScheduleJSON; self.downtimeEnabled = downtimeEnabled
        self.downtimeStart = downtimeStart; self.downtimeEnd = downtimeEnd
        self.manualLock = manualLock; self.taskGateOverride = taskGateOverride
    }
}

@Model
final class CachedAppBlock {
    @Attribute(.unique) var id: String
    var childId: String
    var appName: String
    /// No longer written — blocks point at Evlin's catalog (appId). Kept
    /// only because removing a stored attribute is a riskier store
    /// migration than leaving it unused; new fields below are optional so
    /// existing stores open unchanged.
    var appBundleId: String?
    var blockType: String       // "duration" | "until_task" | "indefinite" | "scheduled"
    var untilTaskId: String?
    var resolved: Bool
    var appId: String?
    /// The server's answer at the last sync: "active", "off_window", …
    var state: String?
    /// "until 'Homework' is approved" — the server's own wording.
    var summary: String?
    /// A duration block's end, so it stops counting on time even offline.
    var endsAt: Date?

    init(id: String, childId: String, appName: String, blockType: String,
         untilTaskId: String?, resolved: Bool, appId: String?, state: String?, summary: String?, endsAt: Date?) {
        self.id = id; self.childId = childId; self.appName = appName; self.appBundleId = nil
        self.blockType = blockType; self.untilTaskId = untilTaskId; self.resolved = resolved
        self.appId = appId; self.state = state; self.summary = summary; self.endsAt = endsAt
    }

    convenience init(_ api: ApiAppBlock) {
        self.init(id: api.id, childId: api.childId, appName: api.appName, blockType: api.blockType,
                  untilTaskId: api.untilTaskId, resolved: api.resolved, appId: api.appId,
                  state: api.state, summary: api.description, endsAt: api.endsAt.flatMap(CalendarSync.parseISO))
    }

    /// Blocking right now, as far as this device can tell. The server's
    /// last word, except a duration block past its end, which has ended
    /// whether or not a sync has happened since.
    func isActive(at now: Date = Date()) -> Bool {
        guard !resolved, state == nil || state == "active" else { return false }
        if blockType == "duration", let endsAt { return now < endsAt }
        return true
    }
}

/// One calendar event (or a kid's plan), as the server sent it. Events are
/// fetched a month at a time; this keeps every one seen, so the calendar
/// opens with them at launch.
@Model
final class CachedEvent {
    @Attribute(.unique) var id: String
    var childId: String
    var startAt: Date
    var recurrence: String
    var json: Data

    init(_ api: ApiEvent, childId: String, startAt: Date, json: Data) {
        id = api.id; self.childId = childId; self.startAt = startAt
        recurrence = api.recurrence; self.json = json
    }

    var event: ApiEvent? { try? JSONDecoder().decode(ApiEvent.self, from: json) }
}

/// The last policy the server sent for this child, kept so the lock and
/// "blocked right now" stay right with no connection. One per child.
@Model
final class CachedPolicy {
    @Attribute(.unique) var childId: String
    var localDate: String
    var json: Data
    var fetchedAt: Date

    init(childId: String, localDate: String, json: Data, fetchedAt: Date) {
        self.childId = childId; self.localDate = localDate; self.json = json; self.fetchedAt = fetchedAt
    }

    var policy: ApiPolicy? { try? JSONDecoder().decode(ApiPolicy.self, from: json) }
}

/// A write that hasn't reached the server yet. Two kinds:
/// - "request": one of the outbox's saved requests (`payload`, see Outbox).
/// - "uploadPhoto": a kid's photo, whose bytes wait on disk at
///   `localFilePath` (TaskDetailView.upload sends these itself).
@Model
final class PendingWrite {
    @Attribute(.unique) var id: String
    var childId: String
    var kind: String   // "request" | "uploadPhoto"
    var occurrenceId: String
    var note: String?
    var localFilePath: String?
    var contentType: String?
    var createdAt: Date
    var attempts: Int
    /// A "request" write's WriteRequest, as JSON.
    var payload: Data?
    /// What the write is, for an error ("Approving the task").
    var label: String?

    convenience init(request: WriteRequest, childId: String, label: String) {
        self.init(childId: childId, kind: "request", occurrenceId: request.occurrence?.localId ?? "")
        payload = try? JSONEncoder().encode(request)
        self.label = label
    }

    var request: WriteRequest? { payload.flatMap { try? JSONDecoder().decode(WriteRequest.self, from: $0) } }

    init(id: String = UUID().uuidString, childId: String, kind: String, occurrenceId: String, note: String? = nil,
         localFilePath: String? = nil, contentType: String? = nil, createdAt: Date = Date(), attempts: Int = 0) {
        self.id = id; self.childId = childId; self.kind = kind; self.occurrenceId = occurrenceId
        self.note = note; self.localFilePath = localFilePath; self.contentType = contentType
        self.createdAt = createdAt; self.attempts = attempts
    }
}

/// Owns the SwiftData container so plain (non-View) code — AppSync,
/// TabletRootView's poll loop — can read/write the cache without needing
/// @Environment(\.modelContext) threaded through. A singleton, same shape
/// as this app's other cross-cutting stores (SessionManager, FamilyStore).
@MainActor
final class LocalStore {
    static let shared = LocalStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Where the store actually ended up. Not cosmetic: enforcement reads
    /// this same database from a *separate process*, so an in-memory
    /// fallback means the app looks fine while anything reading the shared
    /// store sees nothing — and would make lock decisions from nothing.
    /// Recorded rather than swallowed so that's diagnosable.
    enum Backing: String {
        case appGroup           // shared container — readable by an extension
        case localOnly          // app's own container; enforcement can't see it
        case inMemory           // nothing persisted at all
    }

    private(set) static var backing: Backing = .localOnly

    /// The shared container. An enforcement extension runs in its own
    /// process and cannot read the app's private store, so the database has
    /// to live here — and it has to live here from the start, because moving
    /// it later means migrating a store that already has real data on real
    /// devices.
    static let appGroupID = "group.com.evlin.app"

    private init() {
        let schema = Schema([
            CachedTask.self, CachedOccurrence.self, CachedTimeGrant.self, CachedChildState.self,
            CachedAppBlock.self, PendingWrite.self,
            CachedPolicy.self, CachedEvent.self,
        ])

        // Prefer the shared container; fall back only if the App Group isn't
        // provisioned yet (returns nil until the capability is enabled).
        let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent("Evlin.store")

        if let groupURL {
            if let shared = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: groupURL)]) {
                container = shared
                Self.backing = .appGroup
                return
            }
            print("LocalStore: App Group container exists but couldn't be opened — using the app-local store")
        }

        do {
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
            Self.backing = .localOnly
        } catch {
            // A corrupt/incompatible on-disk store (e.g. after a schema
            // change during development) would otherwise crash every
            // launch — an in-memory fallback keeps the app usable for this
            // session rather than stuck permanently unable to start.
            print("LocalStore: falling back to in-memory store: \(error)")
            container = (try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])) ?? {
                fatalError("LocalStore: could not create even an in-memory container: \(error)")
            }()
            Self.backing = .inMemory
        }
    }

    // MARK: - Saving

    private var batchDepth = 0

    /// Runs several writes as one: saved, and the screens rebuilt
    /// (TaskStore.reload), once at the end. A sync uses it so its dozens of
    /// writes redraw once.
    func batch(_ work: () -> Void) {
        batchDepth += 1
        work()
        batchDepth -= 1
        commit()
    }

    /// Saves, then rebuilds what the screens show from the database. Every
    /// write here ends with this, so a screen is never behind its data.
    private func commit() {
        guard batchDepth == 0 else { return }
        try? context.save()
        TaskStore.shared.reload()
    }

    // MARK: - Local file caching (real disk persistence for pending uploads)

    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Writes `data` to a real file in Caches/PendingUploads and returns
    /// its URL — the actual "local temp disk caching" a pending upload
    /// (a photo) is tracked against via PendingWrite, so the bytes
    /// survive the app being killed or backgrounded mid-upload instead of
    /// only ever existing as an in-memory UIImage/Data.
    static func cacheFile(data: Data, suffix: String) -> URL? {
        let url = cacheDir.appendingPathComponent("\(UUID().uuidString).\(suffix)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("LocalStore.cacheFile: \(error)")
            return nil
        }
    }

    // MARK: - Write-through (called by AppSync after a successful fetch)

    /// Makes this child's cached tasks exactly the server's list: updates and
    /// adds, and drops any the server no longer has (deleted, or retired).
    /// It used to only add and update, so every deleted task stayed in the
    /// cache and came back on the next launch until the sync replaced it.
    func saveTasks(_ tasks: [ApiTask], childId: String) {
        tasksCache = nil
        let keep = Set(tasks.map(\.id))
        let cached = (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.childId == childId }))) ?? []
        for row in cached where !keep.contains(row.id) { context.delete(row) }
        for api in tasks {
            let id = api.id
            if let existing = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.id == id })).first {
                existing.title = api.title; existing.instructions = api.instructions; existing.category = api.category
                existing.recurrence = api.recurrence; existing.gatesApps = api.gatesApps
                existing.submissionKind = api.submissionKind; existing.dueDate = api.dueDate; existing.dueTime = api.dueTime
                existing.bonusMinutes = api.bonusMinutes; existing.createdBy = api.createdBy
            } else {
                context.insert(CachedTask(api, childId: childId))
            }
        }
        commit()
    }

    /// Makes this child's cached occurrences for `dueDate` the server's
    /// list, updating rows in place by id. A row the server doesn't have
    /// (one this phone made up offline, or one since removed) goes.
    func saveOccurrences(_ occurrences: [ApiOccurrence], photos: [String: [String]], childId: String, dueDate: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedOccurrence>(
            predicate: #Predicate { $0.childId == childId && $0.dueDate.starts(with: dueDate) }))) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for api in occurrences {
            let row = byId.removeValue(forKey: api.id) ?? {
                let new = CachedOccurrence(api)
                context.insert(new)
                return new
            }()
            row.dueDate = String(api.dueDate.prefix(10))
            row.status = api.status; row.bypassRequested = api.bypassRequested
            row.bypassNote = api.bypassNote; row.rejectionNote = api.rejectionNote
            row.isLocallyMaterialized = false
            row.keepPhotoLinks(photos[api.id] ?? [])
        }
        for row in byId.values { context.delete(row) }
        // Only today matters; earlier days' rows would only pile up.
        try? context.delete(model: CachedOccurrence.self, where: #Predicate { $0.childId == childId && $0.dueDate < dueDate })
        commit()
    }

    func saveTimeGrants(_ summary: ApiTimeGrantsSummary, childId: String) {
        for api in summary.grants {
            let id = api.id
            if (try? context.fetch(FetchDescriptor<CachedTimeGrant>(predicate: #Predicate { $0.id == id })).first) == nil {
                context.insert(CachedTimeGrant(api))
            }
        }
        commit()
    }

    /// The family's children as the server lists them: anyone no longer
    /// listed is removed, with everything kept for them.
    func keepOnlyChildren(_ ids: [String]) {
        let keep = Set(ids)
        let rows = (try? context.fetch(FetchDescriptor<CachedChildState>())) ?? []
        for row in rows where !keep.contains(row.childId) { removeChild(row.childId) }
        commit()
    }

    private func removeChild(_ childId: String) {
        tasksCache = nil
        eventsCache = nil
        try? context.delete(model: CachedChildState.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedTask.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedOccurrence.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedTimeGrant.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedAppBlock.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedPolicy.self, where: #Predicate { $0.childId == childId })
        try? context.delete(model: CachedEvent.self, where: #Predicate { $0.childId == childId })
    }

    /// One child, their rules and state, in the family's order.
    func saveChild(_ apiChild: ApiChild, position: Int, rules: ApiChildRule, state: ApiChildState, availableMinutes: Int?) {
        saveChildState(childId: apiChild.id, childName: apiChild.name, rules: rules, state: state)
        guard let row = cachedChildState(childId: apiChild.id) else { return }
        row.childJSON = try? JSONEncoder().encode(apiChild)
        row.rulesJSON = try? JSONEncoder().encode(rules)
        row.position = position
        if let availableMinutes {
            row.availableMinutes = availableMinutes
            row.availableOn = CalendarSync.isoDay(Date())
        }
        commit()
    }

    func saveChildState(childId: String, childName: String, rules: ApiChildRule, state: ApiChildState) {
        let existing = try? context.fetch(FetchDescriptor<CachedChildState>(predicate: #Predicate { $0.childId == childId })).first
        let row = existing ?? CachedChildState(childId: childId, childName: childName, dailyLimitMinutes: rules.dailyLimitMinutes,
                                                weeklyScheduleJSON: nil, downtimeEnabled: rules.downtimeEnabled,
                                                downtimeStart: rules.downtimeStart, downtimeEnd: rules.downtimeEnd,
                                                manualLock: state.manualLock, taskGateOverride: state.taskGateOverride)
        if existing != nil {
            row.childName = childName
            row.dailyLimitMinutes = rules.dailyLimitMinutes
            row.downtimeEnabled = rules.downtimeEnabled
            row.downtimeStart = rules.downtimeStart
            row.downtimeEnd = rules.downtimeEnd
            row.manualLock = state.manualLock
            row.taskGateOverride = state.taskGateOverride
        }
        row.weeklySchedule = rules.weeklySchedule
        if existing == nil { context.insert(row) }
        commit()
    }

    func saveAppBlocks(_ blocks: [ApiAppBlock], childId: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedAppBlock>(
            predicate: #Predicate { $0.childId == childId }))) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for api in blocks {
            if let row = byId.removeValue(forKey: api.id) {
                row.appName = api.appName; row.blockType = api.blockType; row.untilTaskId = api.untilTaskId
                row.resolved = api.resolved; row.appId = api.appId; row.state = api.state
                row.summary = api.description; row.endsAt = api.endsAt.flatMap(CalendarSync.parseISO)
            } else {
                context.insert(CachedAppBlock(api))
            }
        }
        for row in byId.values { context.delete(row) }
        commit()
    }

    /// One child's events from a fetch of [from, to): updated in place, and
    /// any the same fetch would have returned but didn't (deleted, or moved
    /// out) removed. Mirrors the server's window: everything starting in
    /// it, and every repeat that started before it ends.
    func saveEvents(_ events: [ApiEvent], childId: String, from: Date, to: Date) {
        eventsCache = nil
        let existing = (try? context.fetch(FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.childId == childId }))) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for api in events { upsertEvent(api, existing: byId.removeValue(forKey: api.id)) }
        for row in byId.values where row.startAt <= to && (row.startAt >= from || row.recurrence != "none") {
            context.delete(row)
        }
        commit()
    }

    private func upsertEvent(_ api: ApiEvent, existing: CachedEvent?) {
        eventsCache = nil
        guard let childId = api.childId, let start = CalendarSync.parseISO(api.startAt),
              let json = try? JSONEncoder().encode(api) else { return }
        if let row = existing {
            row.childId = childId; row.startAt = start; row.recurrence = api.recurrence; row.json = json
        } else {
            context.insert(CachedEvent(api, childId: childId, startAt: start, json: json))
        }
    }

    // Decoded once and kept until a task or event is written: a tap (an
    // approval, say) only changes an occurrence, and re-reading and decoding
    // every task and event for each rebuild of the screens took long enough
    // to stall the animation that tap starts.
    private var tasksCache: [String: [ApiTask]]?
    private var eventsCache: [ApiEvent]?

    func allCachedEvents() -> [ApiEvent] {
        if let eventsCache { return eventsCache }
        let events = ((try? context.fetch(FetchDescriptor<CachedEvent>(sortBy: [SortDescriptor(\.startAt)]))) ?? []).compactMap(\.event)
        eventsCache = events
        return events
    }

    /// Every child's tasks, keyed by child.
    func cachedTasksByChild() -> [String: [ApiTask]] {
        if let tasksCache { return tasksCache }
        let byChild = cachedTasksByChildUncached()
        tasksCache = byChild
        return byChild
    }

    private func cachedTasksByChildUncached() -> [String: [ApiTask]] {
        let rows = (try? context.fetch(FetchDescriptor<CachedTask>(sortBy: [SortDescriptor(\.title)]))) ?? []
        return Dictionary(grouping: rows, by: \.childId).mapValues { $0.map { $0.apiShape() } }
    }

    func occurrenceRows(dueDate: String) -> [CachedOccurrence] {
        (try? context.fetch(FetchDescriptor<CachedOccurrence>(predicate: #Predicate { $0.dueDate == dueDate }))) ?? []
    }

    /// A new task that applies today gets today's occurrence on the phone
    /// right away, the way the server will make it, so it's on today's list
    /// (and can be approved) before the server has answered.
    func materializeOccurrence(taskId: String, childId: String, dueDate: String) {
        let exists = !((try? context.fetch(FetchDescriptor<CachedOccurrence>(predicate: #Predicate {
            $0.taskId == taskId && $0.dueDate == dueDate
        }))) ?? []).isEmpty
        guard !exists else { return }
        context.insert(CachedOccurrence(id: UUID().uuidString, taskId: taskId, childId: childId, dueDate: dueDate,
                                        status: "pending", bypassRequested: false, bypassNote: nil,
                                        rejectionNote: nil, isLocallyMaterialized: true))
        commit()
    }

    // MARK: - Cache-first reads (called on launch, before the network sync lands)

    func savePolicy(_ policy: ApiPolicy) {
        guard let json = try? JSONEncoder().encode(policy) else { return }
        let childId = policy.childId
        if let existing = try? context.fetch(FetchDescriptor<CachedPolicy>(
            predicate: #Predicate { $0.childId == childId })).first {
            existing.localDate = policy.localDate; existing.json = json; existing.fetchedAt = Date()
        } else {
            context.insert(CachedPolicy(childId: childId, localDate: policy.localDate, json: json, fetchedAt: Date()))
        }
        commit()
    }

    func cachedPolicy(childId: String) -> ApiPolicy? {
        (try? context.fetch(FetchDescriptor<CachedPolicy>(predicate: #Predicate { $0.childId == childId })))?
            .first?.policy
    }

    func cachedAppBlocks(childId: String) -> [CachedAppBlock] {
        (try? context.fetch(FetchDescriptor<CachedAppBlock>(predicate: #Predicate { $0.childId == childId }))) ?? []
    }

    func cachedTimeGrants(childId: String, creditedDate: String) -> [CachedTimeGrant] {
        (try? context.fetch(FetchDescriptor<CachedTimeGrant>(
            predicate: #Predicate { $0.childId == childId && $0.creditedDate == creditedDate }))) ?? []
    }

    func cachedTasks(childId: String) -> [ApiTask] {
        let rows = (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.childId == childId }))) ?? []
        return rows.map { $0.apiShape() }
    }

    func cachedOccurrences(childId: String, dueDate: String) -> [ApiOccurrence] {
        let rows = (try? context.fetch(FetchDescriptor<CachedOccurrence>(
            predicate: #Predicate { $0.childId == childId && $0.dueDate == dueDate }))) ?? []
        return rows.map {
            ApiOccurrence(id: $0.id, taskId: $0.taskId, childId: $0.childId, dueDate: $0.dueDate, status: $0.status,
                          bypassRequested: $0.bypassRequested, bypassNote: $0.bypassNote, rejectionNote: $0.rejectionNote)
        }
    }

    func cachedChildState(childId: String) -> CachedChildState? {
        try? context.fetch(FetchDescriptor<CachedChildState>(predicate: #Predicate { $0.childId == childId })).first
    }

    /// If nothing's cached for `dueDate` yet (the device has never
    /// successfully synced this specific day — e.g. offline across a day
    /// boundary), self-materialize occurrences from cached task
    /// definitions using the same recurrence rule the backend uses
    /// (CalendarSync.applies — see its own doc comment on why these two
    /// must stay in sync). Idempotent: never creates a second row for a
    /// task that already has one for this date, so nothing conflicts once
    /// a real sync catches up.
    func materializeTodayIfNeeded(childId: String, day: Date, dueDate: String) {
        let alreadyHasRows = !((try? context.fetch(FetchDescriptor<CachedOccurrence>(
            predicate: #Predicate { $0.childId == childId && $0.dueDate == dueDate }))) ?? []).isEmpty
        guard !alreadyHasRows else { return }

        let tasks = (try? context.fetch(FetchDescriptor<CachedTask>(
            predicate: #Predicate { $0.childId == childId && $0.active == true }))) ?? []
        for task in tasks {
            guard CalendarSync.applies(task.apiShape(), on: day) else { continue }
            context.insert(CachedOccurrence(id: UUID().uuidString, taskId: task.id, childId: childId, dueDate: dueDate,
                                             status: "pending", bypassRequested: false, bypassNote: nil,
                                             rejectionNote: nil, isLocallyMaterialized: true))
        }
        commit()
    }

    func localOccurrence(id: String) -> CachedOccurrence? {
        guard let row = try? context.fetch(FetchDescriptor<CachedOccurrence>(predicate: #Predicate { $0.id == id })).first,
              row.isLocallyMaterialized else { return nil }
        return row
    }

    /// The server's id for this task's occurrence on `dueDate`, once a sync
    /// has brought it.
    func serverOccurrenceId(childId: String, taskId: String, dueDate: String) -> String? {
        (try? context.fetch(FetchDescriptor<CachedOccurrence>(predicate: #Predicate {
            $0.childId == childId && $0.taskId == taskId && $0.dueDate == dueDate && $0.isLocallyMaterialized == false
        })))?.first?.id
    }

    // MARK: - Pending writes

    // The outbox's own rows change nothing on screen, so saving them
    // doesn't rebuild the screens (TaskStore.reload): a tap used to rebuild
    // three times, for the change, the queued write, and its removal.
    func queueWrite(_ write: PendingWrite) {
        context.insert(write)
        try? context.save()
    }

    /// The outbox, oldest first.
    func pendingRequests() -> [PendingWrite] {
        (try? context.fetch(FetchDescriptor<PendingWrite>(
            predicate: #Predicate { $0.kind == "request" }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func removeAllPendingRequests() {
        try? context.delete(model: PendingWrite.self, where: #Predicate { $0.kind == "request" })
        try? context.save()
    }

    func saveChanges() { try? context.save() }

    /// Signing out: nothing of the old account stays on the phone.
    func eraseAll() {
        tasksCache = nil
        eventsCache = nil
        for type in [CachedTask.self, CachedOccurrence.self, CachedTimeGrant.self, CachedChildState.self,
                     CachedAppBlock.self, PendingWrite.self, CachedPolicy.self, CachedEvent.self] as [any PersistentModel.Type] {
            try? context.delete(model: type)
        }
        commit()
    }

    // MARK: - Mirrors (a queued write, applied to the phone's copy at once)
    //
    // The screen shows a change the moment it's made, and the outbox sends
    // it. These put it in the database too, so a relaunch before it's sent
    // (offline, say) still shows it.

    func mirrorOccurrence(id: String, status: String? = nil, bypassRequested: Bool? = nil,
                          bypassNote: String? = nil, rejectionNote: String? = nil, clearPhotos: Bool = false) {
        guard let row = try? context.fetch(FetchDescriptor<CachedOccurrence>(predicate: #Predicate { $0.id == id })).first else { return }
        if let status { row.status = status }
        if let bypassRequested { row.bypassRequested = bypassRequested }
        if let bypassNote { row.bypassNote = bypassNote }
        if let rejectionNote { row.rejectionNote = rejectionNote }
        if clearPhotos { row.photoURLs = []; row.photoURLsSavedAt = nil }
        commit()
    }

    func mirrorTaskSaved(_ task: ApiTask, childId: String) {
        tasksCache = nil
        let id = task.id
        if let row = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.id == id })).first {
            row.title = task.title; row.instructions = task.instructions; row.category = task.category
            row.recurrence = task.recurrence; row.dueDate = task.dueDate; row.dueTime = task.dueTime
        } else {
            context.insert(CachedTask(task, childId: childId))
        }
        commit()
    }

    func cachedTask(id: String) -> ApiTask? {
        (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.id == id })))?.first?.apiShape()
    }

    func cachedTaskChild(id: String) -> String? {
        (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.id == id })))?.first?.childId
    }

    func mirrorTaskDeleted(id: String) {
        tasksCache = nil
        try? context.delete(model: CachedTask.self, where: #Predicate { $0.id == id })
        try? context.delete(model: CachedOccurrence.self, where: #Predicate { $0.taskId == id })
        commit()
    }

    func mirrorChildState(childId: String, manualLock: Bool, taskGateOverride: Bool) {
        guard let row = cachedChildState(childId: childId) else { return }
        row.manualLock = manualLock
        row.taskGateOverride = taskGateOverride
        commit()
    }

    func mirrorBlockLifted(id: String) {
        guard let row = try? context.fetch(FetchDescriptor<CachedAppBlock>(predicate: #Predicate { $0.id == id })).first else { return }
        row.resolved = true
        commit()
    }

    func mirrorEventSaved(_ event: ApiEvent) {
        let id = event.id
        upsertEvent(event, existing: try? context.fetch(FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.id == id })).first)
        commit()
    }

    func mirrorEventDeleted(id: String) {
        eventsCache = nil
        try? context.delete(model: CachedEvent.self, where: #Predicate { $0.id == id })
        commit()
    }

    func pendingWrites(childId: String) -> [PendingWrite] {
        (try? context.fetch(FetchDescriptor<PendingWrite>(
            predicate: #Predicate { $0.childId == childId }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func removePendingWrite(_ write: PendingWrite) {
        context.delete(write)
        try? context.save()
    }

    // MARK: - Launch-time hydration

    /// Fills the screens from the database before the network answers, so a
    /// launch (online or not) opens on the family's last known state. Does
    /// nothing once a sync has filled them this session.
    func hydrateIfNeeded() {
        guard FamilyStore.children.isEmpty else { return }
        hydrate()
    }

    /// Builds every child from the database, the way a sync does
    /// (AppSync.makeChild), and rebuilds the task lists and calendar
    /// (TaskStore.reload). Also used when the day changes, so today's lists
    /// move on even with no connection.
    func hydrate() {
        let session = SessionManager.shared
        let isKidDevice = session.parentAccessToken == nil && session.childDeviceToken != nil
        var rows = ((try? context.fetch(FetchDescriptor<CachedChildState>())) ?? [])
            .filter { $0.childJSON != nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        if isKidDevice { rows = rows.filter { $0.childId == session.activeChildId } }
        guard !rows.isEmpty else { return }

        let today = Date()
        let todayKey = CalendarSync.isoDay(today)
        var children: [Child] = []
        for row in rows {
            guard let apiChild = row.apiChild, let rules = row.rules else { continue }
            let id = apiChild.id
            materializeTodayIfNeeded(childId: id, day: today, dueDate: todayKey)

            let available: Int
            if row.availableOn == todayKey, let minutes = row.availableMinutes {
                available = minutes
            } else {
                available = rules.dailyLimitMinutes + cachedTimeGrants(childId: id, creditedDate: todayKey).reduce(0) { $0 + $1.minutes }
            }
            let state = ApiChildState(manualLock: row.manualLock, taskGateOverride: row.taskGateOverride)
            let existing = FamilyStore.children.first { $0.id == id }
            children.append(AppSync.makeChild(apiChild, rules: rules, state: state, availableMinutes: available, existing: existing))
        }
        guard !children.isEmpty else { return }
        FamilyStore.children = children
        if session.activeChildId == nil || !children.contains(where: { $0.id == session.activeChildId }) {
            session.activeChildId = children.first?.id
        }
        TaskStore.shared.reload()
        SyncState.shared.publish()
    }
}
