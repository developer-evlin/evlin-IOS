import XCTest
@testable import Evlin

/// Instant unlock: with it on, work sent in opens the phone without waiting
/// for the parent. Uses the app's own database under a child id no real
/// family has, and removes it afterwards.
@MainActor
final class InstantUnlockTests: XCTestCase {

    private let childId = "test-instant-unlock-child"
    private let taskId = "test-instant-unlock-task"

    override func tearDown() async throws {
        LocalStore.shared.forgetChild(childId)
    }

    private func save(status: String, instantUnlock: Bool) {
        let rules = ApiChildRule(dailyLimitMinutes: 60, downtimeEnabled: false, downtimeStart: nil, downtimeEnd: nil,
                                 dailyLimitEnabled: true, customRules: [], weeklySchedule: nil)
        let store = LocalStore.shared
        store.saveChild(ApiChild(id: childId, name: "Test", colorIndex: 0, isPaired: true, timezone: nil),
                        position: 99, rules: rules,
                        state: ApiChildState(manualLock: false, taskGateOverride: false, instantUnlock: instantUnlock),
                        availableMinutes: 60)
        store.saveTasks([ApiTask(id: taskId, title: "Test task", instructions: nil, recurrence: "daily", gatesApps: true,
                                 submissionKind: "none", bucket: "anytime", category: "Chore", dueDate: nil, dueTime: nil,
                                 createdAt: CalendarSync.isoString(Date()), bonusMinutes: 0, createdBy: "parent")], childId: childId)
        let today = CalendarSync.isoDay(Date())
        store.saveOccurrences([ApiOccurrence(id: "test-instant-unlock-occurrence", taskId: taskId, childId: childId,
                                             dueDate: today, status: status, bypassRequested: false,
                                             bypassNote: nil, rejectionNote: nil)],
                              photos: [:], childId: childId, dueDate: today)
    }

    private var locked: Bool { LocalStore.shared.enforcementState(childId: childId).isLocked }

    func testOffSentInStaysLockedUntilApproved() {
        save(status: "submitted", instantUnlock: false)
        XCTAssertTrue(locked)
        save(status: "approved", instantUnlock: false)
        XCTAssertFalse(locked)
    }

    func testOnSentInOpensIt() {
        save(status: "submitted", instantUnlock: true)
        XCTAssertFalse(locked)
    }

    func testOnWorkNotSentInStaysLocked() {
        save(status: "pending", instantUnlock: true)
        XCTAssertTrue(locked)
    }

    func testOnARedoLocksItAgain() {
        save(status: "rejected", instantUnlock: true)
        XCTAssertTrue(locked)
    }

    func testAServerThatDoesNotSendItLeavesTheSavedChoice() {
        save(status: "submitted", instantUnlock: true)
        let rules = ApiChildRule(dailyLimitMinutes: 60, downtimeEnabled: false, downtimeStart: nil, downtimeEnd: nil,
                                 dailyLimitEnabled: true, customRules: [], weeklySchedule: nil)
        LocalStore.shared.saveChild(ApiChild(id: childId, name: "Test", colorIndex: 0, isPaired: true, timezone: nil),
                                    position: 99, rules: rules, state: ApiChildState(manualLock: false, taskGateOverride: false),
                                    availableMinutes: 60)
        XCTAssertEqual(LocalStore.shared.cachedChildState(childId: childId)?.instantUnlock, true)
    }

    // MARK: Earning it

    private func days(_ trust: inout UnlockTrust, _ count: Int, from start: Int = 1) {
        for i in start..<(start + count) { _ = trust.note(day: "day-\(i)", hasTasks: true, allDone: true) }
    }

    func testTheDaysNeededEarnItAndSaySoOnce() {
        let needed = UnlockTrust.daysNeeded
        XCTAssertEqual(needed, 3)
        var trust = UnlockTrust()
        days(&trust, needed - 1)
        XCTAssertFalse(trust.earned)
        XCTAssertEqual(trust.daysLeft, 1)
        XCTAssertTrue(trust.note(day: "day-\(needed)", hasTasks: true, allDone: true))
        XCTAssertTrue(trust.earned)
        XCTAssertFalse(trust.note(day: "day-\(needed + 1)", hasTasks: true, allDone: true))
    }

    func testADayCountsOnce() {
        var trust = UnlockTrust()
        _ = trust.note(day: "a", hasTasks: true, allDone: true)
        _ = trust.note(day: "a", hasTasks: true, allDone: true)
        XCTAssertEqual(trust.streak, 1)
    }

    func testADayLeftUnfinishedStartsItAgain() {
        var trust = UnlockTrust()
        days(&trust, 3)
        _ = trust.note(day: "x", hasTasks: true, allDone: false)
        _ = trust.note(day: "y", hasTasks: true, allDone: false)
        XCTAssertEqual(trust.streak, 0)
    }

    func testADayWithNoTasksDoesNothing() {
        var trust = UnlockTrust()
        days(&trust, 3)
        _ = trust.note(day: "x", hasTasks: false, allDone: true)
        _ = trust.note(day: "y", hasTasks: true, allDone: true)
        XCTAssertEqual(trust.streak, 4)
    }

    func testAnApprovalTakenBackTakesTheDayBack() {
        var trust = UnlockTrust()
        _ = trust.note(day: "a", hasTasks: true, allDone: true)
        _ = trust.note(day: "a", hasTasks: true, allDone: false)
        XCTAssertEqual(trust.streak, 0)
        _ = trust.note(day: "a", hasTasks: true, allDone: true)
        XCTAssertEqual(trust.streak, 1)
    }

    func testRevokingStartsOverAndTodayDoesNotCountAgain() {
        var trust = UnlockTrust()
        let needed = UnlockTrust.daysNeeded
        days(&trust, needed)
        trust.revoke()
        XCTAssertFalse(trust.earned)
        XCTAssertEqual(trust.daysLeft, needed)
        _ = trust.note(day: "day-\(needed)", hasTasks: true, allDone: true)
        XCTAssertEqual(trust.streak, 0)
        _ = trust.note(day: "day-\(needed + 1)", hasTasks: true, allDone: true)
        XCTAssertEqual(trust.streak, 1)
    }

    func testTrustSurvivesARelaunch() throws {
        let suite = "InstantUnlockTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UnlockTrustStore(defaults: defaults).note(childId: "zoe", day: "a", hasTasks: true, allDone: true)
        XCTAssertEqual(UnlockTrustStore(defaults: defaults).trust(for: "zoe").streak, 1)
    }
}
