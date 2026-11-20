import XCTest
@testable import Evlin

/// Two phones editing the same task or lock never undo each other: only
/// the fields that changed are sent, and every queued write says when it
/// was made (evlin-backend tests/test_idempotency_and_edits.py).
final class ConflictWritesTests: XCTestCase {

    private func task(title: String = "Water the plants", instructions: String? = nil, recurrence: String = "daily",
                      dueTime: String? = nil, icon: String? = "🪴") -> ApiTask {
        ApiTask(id: "t1", title: title, instructions: instructions, recurrence: recurrence, gatesApps: true,
                submissionKind: "none", bucket: "anytime", category: "Chore", dueDate: "2026-11-17",
                dueTime: dueTime, createdAt: nil, bonusMinutes: 0, createdBy: "parent", icon: icon)
    }

    private func json(_ request: WriteRequest) -> [String: Any] {
        (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func testOnlyTheTitleIsSentWhenOnlyTheTitleChanged() {
        let changes = APIClient.Write.taskChanges(from: task(), to: task(title: "Water the garden"))
        XCTAssertEqual(changes.keys.sorted(), ["title"])
        XCTAssertEqual(changes["title"] as? String, "Water the garden")
    }

    func testARepeatChangeLeavesTheTitleOut() {
        let changes = APIClient.Write.taskChanges(from: task(), to: task(recurrence: "sat"))
        XCTAssertEqual(changes.keys.sorted(), ["recurrence"])
    }

    func testATimeRemovedIsSentAsNull() {
        let changes = APIClient.Write.taskChanges(from: task(dueTime: "18:00:00"), to: task(dueTime: nil))
        XCTAssertTrue(changes["due_time"] is NSNull)
        let body = json(APIClient.Write.updateTask(taskId: "t1", fields: changes))
        XCTAssertTrue(body["due_time"] is NSNull)
    }

    func testNothingChangedSendsNothing() {
        XCTAssertTrue(APIClient.Write.taskChanges(from: task(), to: task()).isEmpty)
        // nil and "" instructions are the same.
        XCTAssertTrue(APIClient.Write.taskChanges(from: task(instructions: nil), to: task(instructions: "")).isEmpty)
    }

    func testOnlyTheLockFlagTappedIsSent() {
        let change = Child.stateChange(from: (false, false, false), to: (true, false, false))
        XCTAssertEqual(change.manualLock, true)
        XCTAssertNil(change.taskGateOverride)
        XCTAssertNil(change.instantUnlock)
        let body = json(APIClient.Write.updateChildState(childId: "c1", manualLock: change.manualLock,
                                                         taskGateOverride: change.taskGateOverride,
                                                         instantUnlock: change.instantUnlock))
        XCTAssertEqual(body.keys.sorted(), ["manual_lock"])
    }

    func testWithNothingSavedEveryFlagIsSent() {
        let change = Child.stateChange(from: nil, to: (false, true, false))
        XCTAssertEqual(change.manualLock, false)
        XCTAssertEqual(change.taskGateOverride, true)
        XCTAssertEqual(change.instantUnlock, false)
    }

    func testTheEditTimeIsUTCToTheMillisecond() {
        let date = Date(timeIntervalSince1970: 1_795_000_000.123)
        let text = APIClient.editTime.string(from: date)
        XCTAssertTrue(text.hasSuffix("Z"))
        XCTAssertTrue(text.contains(".123"))
    }
}
