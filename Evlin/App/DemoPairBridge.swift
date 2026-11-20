import Foundation

/// Pairing between two simulators in the Demo app (2026-11-10). The Demo
/// sends nothing to Evlin's server, so there's no real pairing; instead the
/// iPhone and the iPad share one small file on the Mac, named by the launch
/// flag `-EvlinPairBridge <path>` (`scripts/demo-pair.sh` passes it). With
/// it, onboarding pairs for real between the two simulators:
/// - the kid's device shows a fresh code and waits until the parent's phone
///   has typed it;
/// - the parent's phone accepts only that code;
/// - the kid's name, typed on the kid's device after pairing, shows on the
///   parent's phone;
/// - the parent's waiting screen moves on when the kid's device finishes;
/// - after setup, the file stands in for the server for the paired child
///   (`DemoPairSync`): the parent's tasks reach the kid's device, and what
///   the kid sends in and the parent approves goes both ways, so Home's
///   first task can be made, sent in and approved end to end.
/// Without the flag nothing changes. The Evlin scheme's builds compile it
/// out: `isOn` is false and every call does nothing.
enum DemoPairBridge {
    struct State: Codable {
        var code: String?
        var paired = false
        var kidName: String?
        /// "ipad" or "iphone": what the kid's simulator is (`DeviceKind`).
        var kidDevice: String?
        var kidDone = false
        /// Family Sharing's hand-off (`FamilySharingHandOff`).
        var setupStage: String?
        /// The paired child's tasks, as the parent's phone has them.
        var tasks: [ApiTask]?
        /// Today's occurrences of them, the latest from either side.
        var occurrences: [ApiOccurrence]?
    }

    /// The paired child's id on both simulators.
    static let childId = "11111111-1111-4111-8111-111111111111"

    /// The code typed isn't the one on the kid's device.
    static let wrongCode = APIFailure(status: 404, detail: nil)

    #if EVLIN_DEMO
    private static let path: String? = UserDefaults.standard.string(forKey: "EvlinPairBridge")
    static var isOn: Bool { path != nil && DemoMode.previewsOnboarding }

    static func read() -> State? {
        guard isOn, let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func update(_ change: (inout State) -> Void) {
        guard isOn, let path else { return }
        var state = read() ?? State()
        change(&state)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    #else
    static let isOn = false
    static func read() -> State? { nil }
    static func update(_ change: (inout State) -> Void) {}
    #endif

    /// The kid's device: a new code, the file started over.
    @MainActor static func startPairing() -> String {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let kind = DeviceKind.current
        update { $0 = State(code: code, kidDevice: kind) }
        return code
    }
}

#if EVLIN_DEMO
/// The two linked Demo simulators keep the paired child's tasks in step
/// through the bridge file, standing in for the server: the parent's phone
/// owns the tasks; today's occurrences go whichever way one changed (sent
/// in on the kid's device, approved on the parent's). Each side merges
/// into its own database with the same calls a sync uses, so every screen
/// follows as it does after a real sync.
@MainActor
enum DemoPairSync {
    private static var running: Task<Void, Never>?
    /// Each task's occurrence as last agreed (status and skip request).
    private static var lastSeen: [String: String] = [:]
    private static var lastTasks: Data?

    static func start(asParent: Bool) {
        guard DemoPairBridge.isOn, running == nil else { return }
        running = Task { @MainActor in
            while !Task.isCancelled {
                tick(asParent: asParent)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private static func mark(_ o: ApiOccurrence) -> String { "\(o.status)|\(o.bypassRequested)" }

    private static func tick(asParent: Bool) {
        guard let state = DemoPairBridge.read() else { return }
        let store = LocalStore.shared
        let childId = DemoPairBridge.childId
        let today = CalendarSync.isoDay(Date())
        var changedHere = false

        // Tasks: from the parent's phone to the kid's device.
        var pushTasks: [ApiTask]?
        if asParent {
            let tasks = store.cachedTasks(childId: childId).sorted { $0.id < $1.id }
            let data = try? JSONEncoder().encode(tasks)
            if data != lastTasks { lastTasks = data; pushTasks = tasks }
        } else if let tasks = state.tasks {
            let data = try? JSONEncoder().encode(tasks)
            if data != lastTasks {
                lastTasks = data
                store.saveTasks(tasks, childId: childId)
                changedHere = true
            }
        }

        // Today's occurrences, by task: whichever side changed one since
        // they last agreed wins; the first time, the shared one does.
        let mine = Dictionary(store.cachedOccurrences(childId: childId, dueDate: today).map { ($0.taskId, $0) },
                              uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary((state.occurrences ?? []).filter { $0.dueDate.hasPrefix(today) }.map { ($0.taskId, $0) },
                                uniquingKeysWith: { a, _ in a })
        var take: [String: ApiOccurrence] = [:]
        var push: [ApiOccurrence] = []
        for taskId in Set(mine.keys).union(theirs.keys) {
            let seen = lastSeen[taskId]
            if let t = theirs[taskId], seen == nil {
                take[taskId] = t; lastSeen[taskId] = mark(t)
            } else if let m = mine[taskId], mark(m) != seen {
                push.append(m); lastSeen[taskId] = mark(m)
            } else if let t = theirs[taskId], mark(t) != seen {
                take[taskId] = t; lastSeen[taskId] = mark(t)
            }
        }
        if !take.isEmpty {
            let taskIds = Set(store.cachedTasks(childId: childId).map(\.id))
            let merged = Set(mine.keys).union(take.keys).compactMap { take[$0] ?? mine[$0] }
                .filter { taskIds.contains($0.taskId) }
            store.saveOccurrences(merged, photos: [:], childId: childId, dueDate: today)
            changedHere = true
        }

        if pushTasks != nil || !push.isEmpty {
            DemoPairBridge.update { s in
                if let pushTasks { s.tasks = pushTasks }
                var shared = Dictionary((s.occurrences ?? []).map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
                for o in push { shared[o.taskId] = o }
                s.occurrences = Array(shared.values)
            }
        }
        if changedHere { SyncState.shared.publish() }
    }
}
#endif
