import XCTest
@testable import Evlin

/// A repeating task falls on the day the parent added it for as well as its
/// repeat days (2026-11-17): added on Tuesday to repeat on Fridays, it's on
/// that Tuesday, then this Friday and every Friday after, never the Tuesdays
/// after.
final class RepeatAddedDayTests: XCTestCase {

    private func task(_ recurrence: String, addedOn: String?) -> ApiTask {
        ApiTask(id: "t-\(recurrence)-\(addedOn ?? "none")", title: "Water the plants", instructions: nil,
                recurrence: recurrence, gatesApps: true, submissionKind: "none", bucket: "anytime",
                category: nil, dueDate: addedOn, dueTime: nil, createdAt: nil, bonusMinutes: 0,
                createdBy: "parent")
    }

    private func on(_ t: ApiTask, _ day: String) -> Bool {
        CalendarSync.applies(t, on: CalendarSync.parseDay(day)!)
    }

    // 2026-11-17 is a Tuesday; 11-20 a Friday.
    func testAddedTuesdayRepeatingFriday() {
        let t = task("fri", addedOn: "2026-11-17")
        XCTAssertTrue(on(t, "2026-11-17"))    // the day it was added
        XCTAssertFalse(on(t, "2026-11-18"))
        XCTAssertTrue(on(t, "2026-11-20"))    // this Friday
        XCTAssertTrue(on(t, "2026-11-27"))    // every Friday after
        XCTAssertFalse(on(t, "2026-11-24"))   // not the Tuesdays after
        XCTAssertFalse(on(t, "2026-11-13"))   // nor a Friday before it
    }

    func testAddedForAnotherDay() {
        // Tomorrow, or Wednesday picked on This week: Wednesday, then Fridays.
        let t = task("fri", addedOn: "2026-11-18")
        XCTAssertFalse(on(t, "2026-11-17"))
        XCTAssertTrue(on(t, "2026-11-18"))
        XCTAssertTrue(on(t, "2026-11-20"))
        XCTAssertFalse(on(t, "2026-11-25"))
    }

    func testOneOffUnchanged() {
        let t = task("none", addedOn: "2026-11-17")
        XCTAssertTrue(on(t, "2026-11-17"))
        XCTAssertFalse(on(t, "2026-11-20"))
    }
}
