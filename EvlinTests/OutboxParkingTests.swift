import XCTest
@testable import Evlin

/// The app can reach phones before its server is deployed. A write whose
/// route the server doesn't have yet must be kept and set aside: never
/// dropped, never shown to the parent, and never holding up the writes
/// behind it or the sync.
@MainActor
final class OutboxParkingTests: XCTestCase {

    private var savedSession: URLSession!
    private var savedToken: String?

    override func setUp() async throws {
        savedSession = APIClient.shared.session
        savedToken = SessionManager.shared.parentSessionToken
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        APIClient.shared.session = URLSession(configuration: config)
        StubProtocol.reset()
        // A signed-in parent on its own session token: nothing to trade.
        SessionManager.shared.parentSessionToken = "test-session"
        LocalStore.shared.removeAllPendingRequests()
        SyncState.shared.writeError = nil
    }

    override func tearDown() async throws {
        LocalStore.shared.removeAllPendingRequests()
        APIClient.shared.session = savedSession
        SessionManager.shared.parentSessionToken = savedToken
        StubProtocol.reset()
        SyncState.shared.writeError = nil
    }

    func testAWriteTheServerHasNoRouteForIsKeptAsideAndTheRestGoThrough() async {
        StubProtocol.handler = { request in
            request.url!.path.hasSuffix("/unapprove") ? (404, #"{"detail":"Not Found"}"#) : (200, "{}")
        }
        Outbox.send(WriteRequest("POST", "/tasks/occurrences/occ-1/unapprove"), childId: "kid", label: "Undoing the approval")
        Outbox.send(WriteRequest("PUT", "/tasks/task-1", body: ["title": "Make the bed"]), childId: "kid", label: "Your task edit")

        let result = await Outbox.drain()

        XCTAssertTrue(result.isEmpty, "a parked write mustn't hold up the sync")
        XCTAssertTrue(StubProtocol.requests.contains { $0.url!.path == "/tasks/task-1" }, "the write behind it was sent")
        let left = LocalStore.shared.pendingRequests()
        XCTAssertEqual(left.compactMap { $0.request?.path }, ["/tasks/occurrences/occ-1/unapprove"], "kept, not dropped")
        XCTAssertNotNil(left.first?.parkedUntil)
        XCTAssertNil(SyncState.shared.writeError, "nothing shown to the parent")

        // Tried again right away, it stays aside: no second request.
        let before = StubProtocol.requests.count
        _ = await Outbox.drain()
        XCTAssertEqual(StubProtocol.requests.count, before)
    }
}
