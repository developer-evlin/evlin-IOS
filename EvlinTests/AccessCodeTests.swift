import XCTest
@testable import Evlin

/// The screen time access code (`AccessCode`): made and checked by the
/// server (evlin-backend/tests/test_access_codes.py); the phone shows what
/// it's given and counts it down.
final class AccessCodeTests: XCTestCase {

    func testTheServersCodeDecodes() throws {
        let data = Data(#"{"code":"048213","expires_at":"2026-11-19T18:00:00Z","seconds_left":42.5,"lifetime":60}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let answer = try decoder.decode(ApiAccessCode.self, from: data)
        XCTAssertEqual(answer.code, "048213")   // leading zero kept
        XCTAssertEqual(answer.secondsLeft, 42.5)
        XCTAssertEqual(answer.lifetime, 60)
    }

    func testThePieEmptiesOverTheMinute() {
        let now = Date()
        let current = AccessCode.Current(code: "123456", expires: now.addingTimeInterval(30), lifetime: 60)
        XCTAssertEqual(current.fractionLeft(at: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(current.fractionLeft(at: now.addingTimeInterval(45)), 0)
        XCTAssertEqual(current.fractionLeft(at: now.addingTimeInterval(-60)), 1)
    }

    func testSomethingThatIsntSixDigitsIsRefusedWithoutAsking() async throws {
        let short = try await AccessCode.check("12345")
        let letters = try await AccessCode.check("12a456")
        XCTAssertFalse(short)
        XCTAssertFalse(letters)
    }
}
