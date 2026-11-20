import XCTest
@testable import Evlin

/// One day of a repeating task, or the rest of it, deleted or edited on its
/// own: what the phone sends (routers/tasks.py cut and split) and the
/// repeat rule reading the exceptions the server sends back. The days match
/// evlin-backend/tests/test_task_series.py.
final class TaskSeriesTests: XCTestCase {

    private func task(_ recurrence: String, addedOn: String, skipped: [String]? = nil, until: String? = nil) -> ApiTask {
        ApiTask(id: "t-\(recurrence)-\(skipped?.joined() ?? "")-\(until ?? "")", title: "Water the plants",
                instructions: nil, recurrence: recurrence, gatesApps: true, submissionKind: "none",
                bucket: "anytime", category: nil, dueDate: addedOn, dueTime: nil, createdAt: nil,
                bonusMinutes: 0, createdBy: "parent", skippedDates: skipped, repeatUntil: until)
    }

    private func on(_ t: ApiTask, _ day: String) -> Bool {
        CalendarSync.applies(t, on: CalendarSync.parseDay(day)!)
    }

    private func json(_ request: WriteRequest) -> [String: Any] {
        (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func testSkippedDayAndLastDay() {
        let t = task("daily", addedOn: "2026-11-17", skipped: ["2026-11-18"], until: "2026-11-20")
        XCTAssertTrue(on(t, "2026-11-17"))
        XCTAssertFalse(on(t, "2026-11-18"))   // taken out
        XCTAssertTrue(on(t, "2026-11-20"))    // its last day
        XCTAssertFalse(on(t, "2026-11-21"))
    }

    func testSkippingTheAddedDayWins() {
        XCTAssertFalse(on(task("fri", addedOn: "2026-11-17", skipped: ["2026-11-17"]), "2026-11-17"))
    }

    func testCutOneDayAndFromADayOn() {
        let one = APIClient.Write.cutTask(taskId: "abc", from: "2026-11-18", through: "2026-11-18")
        XCTAssertEqual(one.method, "POST")
        XCTAssertEqual(one.path, "/tasks/abc/cut")
        XCTAssertEqual(json(one)["from"] as? String, "2026-11-18")
        XCTAssertEqual(json(one)["through"] as? String, "2026-11-18")

        let rest = APIClient.Write.cutTask(taskId: "abc", from: "2026-11-20", through: nil)
        XCTAssertNil(json(rest)["through"])
    }

    func testSplitCarriesTheNewTaskWithThePhonesId() {
        let made = APIClient.Write.createTask(id: "new-id", childId: "kid", title: "Water the garden", instructions: nil,
                                              recurrence: "none", category: "Chore", submissionKind: "none",
                                              dueDate: "2026-11-18")
        let split = APIClient.Write.splitTask(taskId: "old-id", from: "2026-11-18", through: "2026-11-18", newTask: made)
        XCTAssertEqual(split.path, "/tasks/old-id/split")
        let body = json(split)
        XCTAssertEqual(body["from"] as? String, "2026-11-18")
        let inner = body["task"] as? [String: Any]
        XCTAssertEqual(inner?["id"] as? String, "new-id")
        XCTAssertEqual(inner?["title"] as? String, "Water the garden")
        XCTAssertEqual(inner?["due_date"] as? String, "2026-11-18")
        // No id at the top: the outbox's id adoption leaves it alone.
        XCTAssertNil(body["id"])
    }

    func testTheServersExceptionsDecode() throws {
        let data = Data("""
        {"id":"t1","title":"Water the plants","instructions":null,"recurrence":"daily","gates_apps":true,
         "submission_kind":"none","bucket":"anytime","category":null,"due_date":"2026-11-17","due_time":null,
         "created_at":"2026-11-17T10:00:00Z","bonus_minutes":0,"created_by":"parent",
         "skipped_dates":["2026-11-18"],"repeat_until":"2026-11-26"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let t = try decoder.decode(ApiTask.self, from: data)
        XCTAssertEqual(t.skippedDates, ["2026-11-18"])
        XCTAssertEqual(t.repeatUntil, "2026-11-26")
        XCTAssertFalse(on(t, "2026-11-18"))
        XCTAssertFalse(on(t, "2026-11-27"))
    }
}
