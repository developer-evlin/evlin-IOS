import Foundation
import SwiftData

// The kid's device had zero local persistence before this — FamilyStore/
// TaskStore are plain in-memory statics, wiped on every relaunch and fully
// repopulated from the network (see AppSync.syncKidDevice). Zero internet
// on the kid's device meant an empty app. These SwiftData models mirror
// enough of the real backend shape (tasks, occurrences, the time-grant
// ledger, child state) to render and act on with no connectivity, then
// reconcile with the server once it's reachable again.
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
    // A special task's course, cached so the kid can still see which task
    // needs which course with no connectivity.
    var courseAssignmentId: String?
    var milestoneId: String?

    init(id: String, childId: String, title: String, instructions: String?, category: String?,
         recurrence: String, gatesApps: Bool, submissionKind: String, dueDate: String?, dueTime: String?,
         active: Bool, bonusMinutes: Int, createdBy: String, createdAt: String?,
         courseAssignmentId: String? = nil, milestoneId: String? = nil) {
        self.id = id; self.childId = childId; self.title = title; self.instructions = instructions
        self.category = category; self.recurrence = recurrence; self.gatesApps = gatesApps
        self.submissionKind = submissionKind; self.dueDate = dueDate; self.dueTime = dueTime
        self.active = active; self.bonusMinutes = bonusMinutes; self.createdBy = createdBy
        self.createdAt = createdAt
        self.courseAssignmentId = courseAssignmentId; self.milestoneId = milestoneId
    }

    convenience init(_ api: ApiTask, childId: String) {
        self.init(id: api.id, childId: childId, title: api.title, instructions: api.instructions,
                   category: api.category, recurrence: api.recurrence, gatesApps: api.gatesApps,
                   submissionKind: api.submissionKind, dueDate: api.dueDate, dueTime: api.dueTime,
                   active: true, bonusMinutes: api.bonusMinutes, createdBy: api.createdBy, createdAt: api.createdAt,
                   courseAssignmentId: api.courseAssignmentId, milestoneId: api.milestoneId)
    }

    func apiShape() -> ApiTask {
        ApiTask(id: id, title: title, instructions: instructions, recurrence: recurrence, gatesApps: gatesApps,
                submissionKind: submissionKind, bucket: "anytime", category: category, dueDate: dueDate,
                dueTime: dueTime, createdAt: createdAt, bonusMinutes: bonusMinutes, createdBy: createdBy,
                courseAssignmentId: courseAssignmentId, milestoneId: milestoneId)
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

    init(id: String, taskId: String, childId: String, dueDate: String, status: String,
         bypassRequested: Bool, bypassNote: String?, rejectionNote: String?, isLocallyMaterialized: Bool) {
        self.id = id; self.taskId = taskId; self.childId = childId; self.dueDate = dueDate
        self.status = status; self.bypassRequested = bypassRequested; self.bypassNote = bypassNote
        self.rejectionNote = rejectionNote; self.isLocallyMaterialized = isLocallyMaterialized
    }

    convenience init(_ api: ApiOccurrence) {
        self.init(id: api.id, taskId: api.taskId, childId: api.childId, dueDate: api.dueDate, status: api.status,
                   bypassRequested: api.bypassRequested, bypassNote: api.bypassNote, rejectionNote: api.rejectionNote,
                   isLocallyMaterialized: false)
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

/// An open reflection is the highest-priority gate: while one exists the
/// device is locked regardless of task status. Cached so that stays true
/// with no connectivity — and so it survives the app being killed, which is
/// otherwise an obvious way out of a lock.
@Model
final class CachedReflection {
    @Attribute(.unique) var id: String
    var childId: String
    var courseAssignmentId: String
    var writtenPrompt: String?
    var status: String    // "pending" | "submitted" | "approved" | "needs_redo"

    init(id: String, childId: String, courseAssignmentId: String, writtenPrompt: String?, status: String) {
        self.id = id; self.childId = childId; self.courseAssignmentId = courseAssignmentId
        self.writtenPrompt = writtenPrompt; self.status = status
    }

    convenience init(_ api: ApiReflection) {
        self.init(id: api.id, childId: api.childId, courseAssignmentId: api.courseAssignmentId,
                   writtenPrompt: api.writtenPrompt, status: api.status)
    }

    /// Pending *or* awaiting review — handing something in doesn't hand the
    /// device back.
    var isOpen: Bool { status == "pending" || status == "submitted" }
}

@Model
final class CachedAppBlock {
    @Attribute(.unique) var id: String
    var childId: String
    var appName: String
    var appBundleId: String?
    var blockType: String       // "duration" | "until_task"
    var untilTaskId: String?
    var resolved: Bool

    init(id: String, childId: String, appName: String, appBundleId: String?, blockType: String,
         untilTaskId: String?, resolved: Bool) {
        self.id = id; self.childId = childId; self.appName = appName; self.appBundleId = appBundleId
        self.blockType = blockType; self.untilTaskId = untilTaskId; self.resolved = resolved
    }

    convenience init(_ api: ApiAppBlock) {
        self.init(id: api.id, childId: api.childId, appName: api.appName, appBundleId: api.appBundleId,
                   blockType: api.blockType, untilTaskId: api.untilTaskId, resolved: api.resolved)
    }
}

@Model
final class CachedMilestone {
    @Attribute(.unique) var id: String
    var childId: String
    var title: String
    var kind: String
    var targetCount: Int?
    var progressCount: Int
    var prizeText: String?
    var prizeMinutes: Int
    var status: String
    var achievable: Bool

    init(id: String, childId: String, title: String, kind: String, targetCount: Int?, progressCount: Int,
         prizeText: String?, prizeMinutes: Int, status: String, achievable: Bool) {
        self.id = id; self.childId = childId; self.title = title; self.kind = kind
        self.targetCount = targetCount; self.progressCount = progressCount; self.prizeText = prizeText
        self.prizeMinutes = prizeMinutes; self.status = status; self.achievable = achievable
    }

    convenience init(_ api: ApiMilestone) {
        self.init(id: api.id, childId: api.childId, title: api.title, kind: api.kind,
                   targetCount: api.targetCount, progressCount: api.progressCount, prizeText: api.prizeText,
                   prizeMinutes: api.prizeMinutes, status: api.status, achievable: api.achievable)
    }
}

/// One kid-device write that couldn't reach the server yet — submit a
/// task, request a bypass, or a photo/voice upload. Recorded instead of
/// just failing so a relaunch doesn't lose it. `localFileURL` keeps a
/// captured photo/voice note's actual bytes on disk (not just in the
/// in-memory `photos`/`CapturedPhoto` array TaskDetailView already holds),
/// since those would otherwise be gone the moment the app is killed while
/// offline.
@Model
final class PendingWrite {
    @Attribute(.unique) var id: String
    var childId: String
    var kind: String   // "submitTask" | "requestBypass" | "uploadPhoto" | "uploadVoice"
    var occurrenceId: String
    var note: String?
    var localFilePath: String?
    var contentType: String?
    var createdAt: Date
    var attempts: Int

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
            CachedReflection.self, CachedAppBlock.self, CachedMilestone.self, PendingWrite.self,
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

    // MARK: - Local file caching (real disk persistence for pending uploads)

    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Writes `data` to a real file in Caches/PendingUploads and returns
    /// its URL — the actual "local temp disk caching" a pending upload
    /// (photo or voice) is tracked against via PendingWrite, so the bytes
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

    func saveTasks(_ tasks: [ApiTask], childId: String) {
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
        try? context.save()
    }

    /// Replaces this child's cached occurrences for `dueDate` with the
    /// server's authoritative list — including dropping any locally
    /// materialized row for that date the real sync has now superseded.
    func saveOccurrences(_ occurrences: [ApiOccurrence], childId: String, dueDate: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedOccurrence>(
            predicate: #Predicate { $0.childId == childId && $0.dueDate == dueDate }))) ?? []
        for row in existing { context.delete(row) }
        for api in occurrences { context.insert(CachedOccurrence(api)) }
        try? context.save()
    }

    func saveTimeGrants(_ summary: ApiTimeGrantsSummary, childId: String) {
        for api in summary.grants {
            let id = api.id
            if (try? context.fetch(FetchDescriptor<CachedTimeGrant>(predicate: #Predicate { $0.id == id })).first) == nil {
                context.insert(CachedTimeGrant(api))
            }
        }
        try? context.save()
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
        try? context.save()
    }

    func saveReflections(_ reflections: [ApiReflection], childId: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedReflection>(
            predicate: #Predicate { $0.childId == childId }))) ?? []
        for row in existing { context.delete(row) }
        for api in reflections { context.insert(CachedReflection(api)) }
        try? context.save()
    }

    func saveAppBlocks(_ blocks: [ApiAppBlock], childId: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedAppBlock>(
            predicate: #Predicate { $0.childId == childId }))) ?? []
        for row in existing { context.delete(row) }
        for api in blocks { context.insert(CachedAppBlock(api)) }
        try? context.save()
    }

    func saveMilestones(_ milestones: [ApiMilestone], childId: String) {
        let existing = (try? context.fetch(FetchDescriptor<CachedMilestone>(
            predicate: #Predicate { $0.childId == childId }))) ?? []
        for row in existing { context.delete(row) }
        for api in milestones { context.insert(CachedMilestone(api)) }
        try? context.save()
    }

    // MARK: - Cache-first reads (called on launch, before the network sync lands)

    func cachedReflections(childId: String) -> [CachedReflection] {
        (try? context.fetch(FetchDescriptor<CachedReflection>(predicate: #Predicate { $0.childId == childId }))) ?? []
    }

    func cachedAppBlocks(childId: String) -> [CachedAppBlock] {
        (try? context.fetch(FetchDescriptor<CachedAppBlock>(predicate: #Predicate { $0.childId == childId }))) ?? []
    }

    func cachedMilestones(childId: String) -> [CachedMilestone] {
        (try? context.fetch(FetchDescriptor<CachedMilestone>(predicate: #Predicate { $0.childId == childId }))) ?? []
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
        try? context.save()
    }

    // MARK: - Pending writes (kid-device actions made while offline)

    func queueWrite(_ write: PendingWrite) {
        context.insert(write)
        try? context.save()
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

    /// Populates FamilyStore/TaskStore from the local cache — called before
    /// the first network sync has any chance to land, so a fully offline
    /// launch (or a slow/failing one) still shows real, previously-synced
    /// data instead of an empty screen. A no-op once the real sync has
    /// already populated this child (never overwrites fresher in-memory
    /// state with a stale cache read). Skips anything that needs a live
    /// network call to be meaningful (photo/voice URLs) — those fill in
    /// once the real sync succeeds, same as any other secondary data.
    func hydrateIfNeeded(childId: String) {
        guard FamilyStore.children.first(where: { $0.id == childId }) == nil else { return }
        guard let cachedState = cachedChildState(childId: childId) else { return }
        let cachedTasksList = cachedTasks(childId: childId)
        guard !cachedTasksList.isEmpty else { return }

        let today = Date()
        let todayKey = CalendarSync.isoDay(today)
        materializeTodayIfNeeded(childId: childId, day: today, dueDate: todayKey)
        let todaysOccurrences = cachedOccurrences(childId: childId, dueDate: todayKey)

        var uiTasks: [ChildTask] = []
        for task in cachedTasksList {
            let occurrence = todaysOccurrences.first(where: { $0.taskId == task.id })
            let bypass = occurrence?.bypassRequested ?? false
            let uiState: TaskState
            switch occurrence?.status {
            case "approved": uiState = bypass ? .bypassed : .done
            case "submitted": uiState = .review
            case "rejected": uiState = .pending
            default: uiState = bypass ? .bypass : .pending
            }
            var redoNote: String? = nil
            if occurrence?.status == "rejected" {
                let n = occurrence?.rejectionNote ?? ""
                redoNote = n.isEmpty ? "Please try again." : n
            }
            var dueDate: Date? = nil
            var dueLabel: String? = nil
            if occurrence == nil {
                dueDate = CalendarSync.nextOccurrence(of: task, after: today)
            } else if let time = CalendarSync.parseTime(task.dueTime) {
                dueDate = CalendarSync.date(on: today, minutes: time)
                dueLabel = CalendarSync.clock(minutes: time)
            }
            uiTasks.append(ChildTask(
                id: task.id, occurrenceId: occurrence?.id, title: task.title, state: uiState,
                category: task.category ?? task.bucket, description: task.instructions ?? "",
                note: occurrence?.bypassNote, dueLabel: dueLabel, dueDate: dueDate,
                repeats: CalendarSync.repeatCodes(task.recurrence), redoNote: redoNote
            ))
        }
        TaskStore.binding(for: childId).wrappedValue = uiTasks.sortedForReview()

        let grants = (try? context.fetch(FetchDescriptor<CachedTimeGrant>(
            predicate: #Predicate { $0.childId == childId && $0.creditedDate == todayKey }))) ?? []
        let available = cachedState.dailyLimitMinutes + grants.reduce(0) { $0 + $1.minutes }

        let palette = FamilyStore.childColorPalette
        let child = Child(
            id: childId, name: cachedState.childName, age: 10,
            dailyLimitMin: cachedState.dailyLimitMinutes, color: palette[0],
            manualLock: cachedState.manualLock, taskGateOverride: cachedState.taskGateOverride,
            timeLeft: formatMinutes(max(0, available)), timePct: 100, usageTodayMin: 0,
            subtitle: "Offline — showing your last synced data"
        )
        FamilyStore.children = [child]
        SyncState.shared.version += 1
    }
}
