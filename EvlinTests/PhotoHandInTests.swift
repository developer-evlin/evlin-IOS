import XCTest
@testable import Evlin

/// A kid's Send and its photos arrive together (2026-11-19): Send waits in
/// the outbox while a photo it names is still uploading, without holding up
/// anything else or calling it a connection problem, and a photo the server
/// says it never got is uploaded again and Send repeated.
@MainActor
final class PhotoHandInTests: XCTestCase {

    private var savedSession: URLSession!
    private var savedToken: String?
    private var files: [URL] = []

    override func setUp() async throws {
        savedSession = APIClient.shared.session
        savedToken = SessionManager.shared.parentSessionToken
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        APIClient.shared.session = URLSession(configuration: config)
        StubProtocol.reset()
        SessionManager.shared.parentSessionToken = "test-session"
        clear()
        SyncState.shared.syncError = nil
    }

    override func tearDown() async throws {
        clear()
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        APIClient.shared.session = savedSession
        SessionManager.shared.parentSessionToken = savedToken
        StubProtocol.reset()
        SyncState.shared.syncError = nil
    }

    private func clear() {
        LocalStore.shared.removeAllPendingRequests()
        for write in LocalStore.shared.uploadWrites() { LocalStore.shared.removePendingWrite(write) }
    }

    /// A photo taken for occ-1, its file saved, not up yet (or up).
    @discardableResult
    private func photo(_ photoId: String, uploaded: Bool) -> PendingWrite {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).heic")
        try? Data("photo".utf8).write(to: file)
        files.append(file)
        let write = PendingWrite(childId: "kid", kind: "uploadPhoto", occurrenceId: "occ-1",
                                 localFilePath: file.path, contentType: "image/heic")
        write.photoId = photoId
        write.payload = try? JSONEncoder().encode(APIClient.Write.photoSlot(
            occurrenceId: "occ-1", photoId: photoId, contentType: "image/heic", bytes: 5))
        if uploaded { write.uploadedAt = Date() }
        LocalStore.shared.queueWrite(write)
        return write
    }

    func testSendWaitsForItsPhotoAndTheRestStillGo() async {
        // The photo's slot can't be had right now: it stays not up.
        StubProtocol.handler = { request in
            request.url!.path.hasSuffix("/submissions") ? (503, #"{"detail":"busy"}"#) : (200, "{}")
        }
        photo("photo-1", uploaded: false)
        Outbox.send(APIClient.Write.submitTask(occurrenceId: "occ-1", photoIds: ["photo-1"]), childId: "kid", label: "Your task")
        Outbox.send(APIClient.Write.nameMyChild("Mia"), childId: "kid", label: "Your name")

        let result = await Outbox.drain()

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.waitingOnPhotos, "waiting for a photo, not offline")
        XCTAssertFalse(StubProtocol.requests.contains { $0.url!.path.hasSuffix("/submit") }, "Send waits for the photo")
        XCTAssertTrue(StubProtocol.requests.contains { $0.url!.path == "/device/me" }, "the write behind it went")
        XCTAssertEqual(LocalStore.shared.pendingRequests().compactMap { $0.request?.photoIds }, [["photo-1"]])
    }

    func testSendGoesOnceItsPhotoIsUp() async {
        StubProtocol.handler = { _ in (200, #"{"missing_photo_ids":[]}"#) }
        photo("photo-1", uploaded: true)
        Outbox.send(APIClient.Write.submitTask(occurrenceId: "occ-1", photoIds: ["photo-1"]), childId: "kid", label: "Your task")

        let result = await Outbox.drain()

        XCTAssertTrue(result.isEmpty)
        let submit = StubProtocol.requests.first { $0.url!.path.hasSuffix("/submit") }
        XCTAssertNotNil(submit)
        XCTAssertTrue(LocalStore.shared.uploadWrites().isEmpty, "the photo's file and entry are done with")
    }

    func testAPhotoTheServerNeverGotIsUploadedAgainAndSendRepeated() {
        let lost = photo("photo-lost", uploaded: true)
        photo("photo-fine", uploaded: true)
        let send = APIClient.Write.submitTask(occurrenceId: "occ-1", photoIds: ["photo-lost", "photo-fine"])

        PhotoUploads.shared.sendAccepted(send, answer: Data(#"{"missing_photo_ids":["PHOTO-LOST"]}"#.utf8),
                                         childId: "kid", label: "Your task")

        let left = LocalStore.shared.uploadWrites()
        XCTAssertEqual(left.map(\.photoId), ["photo-lost"], "the photo the server has is done with")
        XCTAssertNil(lost.uploadedAt, "the lost one goes up again")
        XCTAssertEqual(LocalStore.shared.pendingRequests().compactMap { $0.request?.photoIds }, [["photo-lost", "photo-fine"]],
                       "Send is repeated once it's up")
    }
}
