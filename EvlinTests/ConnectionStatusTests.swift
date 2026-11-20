import XCTest
@testable import Evlin

/// The connection pill: nothing for a short blip, a calm "offline" (with
/// what's waiting) once it lasts, and a brief "all saved" when the waiting
/// changes go through.
@MainActor
final class ConnectionStatusTests: XCTestCase {

    override func setUp() async throws {
        let s = ConnectionStatus.shared
        s.setServerTrouble(false)
        s.setWaiting(0)
        s.setOnline(true)
        try await Task.sleep(for: .seconds(2.2))   // let any "all saved" clear
    }

    func testAShortBlipShowsNothing() async throws {
        let s = ConnectionStatus.shared
        s.setOnline(false)
        try await Task.sleep(for: .seconds(1))
        s.setOnline(true)
        XCTAssertEqual(s.phase, .fine)
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertEqual(s.phase, .fine, "a blip under 3 seconds never shows")
    }

    func testOfflineWithChangesWaitingThenAllSaved() async throws {
        let s = ConnectionStatus.shared
        s.setOnline(false)
        s.setWaiting(2)
        try await Task.sleep(for: .seconds(3.3))
        XCTAssertEqual(s.phase, .offline(waiting: 2))

        s.setWaiting(3)
        XCTAssertEqual(s.phase, .offline(waiting: 3), "the count stays current while shown")

        s.setOnline(true)
        s.setWaiting(0)
        XCTAssertEqual(s.phase, .caughtUp)
        try await Task.sleep(for: .seconds(2.3))
        XCTAssertEqual(s.phase, .fine)
    }

    func testServerTroubleWhileOnline() async throws {
        let s = ConnectionStatus.shared
        s.setServerTrouble(true)
        try await Task.sleep(for: .seconds(3.3))
        XCTAssertEqual(s.phase, .unreachable(waiting: 0))
        s.setServerTrouble(false)
        XCTAssertEqual(s.phase, .fine)
    }
}
