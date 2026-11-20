import XCTest
@testable import Evlin

/// A server too old to take the phone's id makes a task under its own id.
/// The phone's row must take that id in place, so the next sync matches it
/// instead of deleting the phone's row and adding the server's as new,
/// which made the row blink out and back in on Home.
///
/// Uses the app's own database under a child id no real family has, and
/// removes what it made.
@MainActor
final class ServerIdAdoptionTests: XCTestCase {

    private let childId = "test-adopt-child"
    private let localId = "aaaaaaaa-0000-4000-8000-000000000001"
    private let serverId = "bbbbbbbb-0000-4000-8000-000000000002"
    private let today = CalendarSync.isoDay(Date())

    override func tearDown() async throws {
        let store = LocalStore.shared
        store.saveTasks([], childId: childId)
        store.saveOccurrences([], photos: [:], childId: childId, dueDate: today)
        for write in store.pendingRequests() where write.childId == childId { store.removePendingWrite(write) }
    }

    private func task(id: String, createdAt: String) -> ApiTask {
        ApiTask(id: id, title: "Water plants", instructions: nil, recurrence: "none", gatesApps: true,
                submissionKind: "none", bucket: "anytime", category: "Chore", dueDate: today,
                dueTime: "20:00:00", createdAt: createdAt, bonusMinutes: 0, createdBy: "parent")
    }

    func testTheNextSyncFindsTheRowInsteadOfReplacingIt() {
        let store = LocalStore.shared
        let phoneCreated = "2026-10-14T09:00:00Z"
        store.mirrorTaskSaved(task(id: localId, createdAt: phoneCreated), childId: childId)
        store.materializeOccurrence(taskId: localId, childId: childId, dueDate: today)
        // An edit queued before the create was answered names the phone's id.
        Outbox.send(WriteRequest("PUT", "/tasks/\(localId)", body: ["title": "Water the plants"]),
                    childId: childId, label: "test")

        store.adoptServerId(serverId, for: localId)

        let rows = store.cachedTasksByChild()[childId] ?? []
        XCTAssertEqual(rows.map(\.id), [serverId])
        XCTAssertEqual(rows.first?.createdAt, phoneCreated, "keeps its place in the list")
        XCTAssertEqual(store.occurrenceRows(dueDate: today).filter { $0.childId == childId }.map(\.taskId), [serverId])
        let paths = store.pendingRequests().filter { $0.childId == childId }.compactMap { $0.request?.path }
        XCTAssertEqual(paths, ["/tasks/\(serverId)"], "the waiting edit goes to the server's row")

        // The sync then brings the server's copy: same row, nothing removed.
        store.saveTasks([task(id: serverId, createdAt: "2026-10-14T09:00:03.123456+00:00")], childId: childId)
        XCTAssertEqual((store.cachedTasksByChild()[childId] ?? []).map(\.id), [serverId])
    }

    func testASyncThatAlreadyBroughtTheServersRowLeavesOne() {
        let store = LocalStore.shared
        store.mirrorTaskSaved(task(id: localId, createdAt: "2026-10-14T09:00:00Z"), childId: childId)
        // The server's copy arrived before the create's answer was handled.
        store.mirrorTaskSaved(task(id: serverId, createdAt: "2026-10-14T09:00:03Z"), childId: childId)

        store.adoptServerId(serverId, for: localId)

        XCTAssertEqual((store.cachedTasksByChild()[childId] ?? []).map(\.id), [serverId])
    }
}
