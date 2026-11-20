import XCTest
@testable import Evlin

/// Extra time a parent gives shows at once: the phone adds it to today's
/// total while the grant waits in the outbox, instead of waiting for the
/// server (which, offline, never answered, so the button seemed dead).
///
/// Uses the app's own database under a child id no real family has, and
/// removes it afterwards.
@MainActor
final class TimeGrantMirrorTests: XCTestCase {

    private let childId = "test-grant-child"

    override func tearDown() async throws {
        LocalStore.shared.forgetChild(childId)
    }

    private func save(availableMinutes: Int?, weekly: [String: Int]? = nil) {
        let rules = ApiChildRule(dailyLimitMinutes: 60, downtimeEnabled: false, downtimeStart: nil, downtimeEnd: nil,
                                 dailyLimitEnabled: true, customRules: [], weeklySchedule: weekly)
        LocalStore.shared.saveChild(ApiChild(id: childId, name: "Test", colorIndex: 0, isPaired: true, timezone: nil),
                                    position: 99, rules: rules,
                                    state: ApiChildState(manualLock: false, taskGateOverride: false),
                                    availableMinutes: availableMinutes)
    }

    func testAGrantAddsToTodaysTotalAtOnce() {
        save(availableMinutes: 0)   // out of time
        XCTAssertEqual(LocalStore.shared.mirrorTimeGrant(childId: childId, minutes: 15), 15)
        XCTAssertEqual(LocalStore.shared.mirrorTimeGrant(childId: childId, minutes: 30), 45)
        XCTAssertEqual(LocalStore.shared.cachedChildState(childId: childId)?.availableMinutes, 45,
                       "saved, so a relaunch before the grant is sent still shows it")
    }

    func testWithNoTotalFromTheServerTodayItStartsFromTodaysLimit() {
        save(availableMinutes: nil)
        let today = EnforcementCalculator.weekdayCode(for: Date())
        save(availableMinutes: nil, weekly: Dictionary(uniqueKeysWithValues: ScreenTimeSchedule.days.map { ($0, $0 == today ? 120 : 60) }))
        XCTAssertEqual(LocalStore.shared.mirrorTimeGrant(childId: childId, minutes: 15), 135,
                       "today's own limit from the custom schedule, plus the grant")
    }
}
