import XCTest
@testable import Evlin

/// Does a signed-in parent (or a paired kid's phone) stay signed in?
///
/// - "After a rebuild": a relaunch builds a fresh SessionManager, which has
///   only the Keychain and UserDefaults to go on. A new build installed over
///   the old one keeps both (same bundle id and team).
/// - "After a while": the access token lasts about an hour. The app must
///   trade the refresh token for a new one, and sign out only when the
///   server refuses the refresh token, never over an outage.
///
/// Nothing here reaches the network: `StubProtocol` answers every request.
@MainActor
final class SessionPersistenceTests: XCTestCase {

    private let keys = ["parentAccess", "parentRefresh", "childDevice", "activeChild"]
    private var savedKeychain: [String: String?] = [:]
    private var savedDefaults: [String: Any?] = [:]
    private var savedSession: URLSession!
    private var expiredNotices = 0
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        // Leave the simulator's own sign-in as it was.
        for key in keys { savedKeychain.updateValue(KeychainStore.get(key), forKey: key) }
        let d = UserDefaults.standard
        for key in [RootView.Saved.mode, RootView.Saved.parent, RootView.Saved.child] {
            savedDefaults.updateValue(d.object(forKey: key), forKey: key)
        }
        savedSession = APIClient.shared.session

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        APIClient.shared.session = URLSession(configuration: config)
        StubProtocol.reset()

        expiredNotices = 0
        observer = NotificationCenter.default.addObserver(
            forName: .evlinSessionExpired, object: nil, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.expiredNotices += 1 } }
    }

    override func tearDown() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        APIClient.shared.session = savedSession
        for (key, value) in savedKeychain { KeychainStore.set(value, for: key) }
        let s = SessionManager.shared
        s.parentAccessToken = KeychainStore.get("parentAccess")
        s.parentRefreshToken = KeychainStore.get("parentRefresh")
        s.childDeviceToken = KeychainStore.get("childDevice")
        s.activeChildId = KeychainStore.get("activeChild")
        let d = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    // MARK: - After a rebuild (relaunch)

    func testParentTokensSurviveARelaunch() {
        SessionManager.shared.parentAccessToken = "access-1"
        SessionManager.shared.parentRefreshToken = "refresh-1"

        // What the next launch builds: nothing but what was saved.
        let relaunched = SessionManager()

        XCTAssertEqual(relaunched.parentAccessToken, "access-1")
        XCTAssertEqual(relaunched.parentRefreshToken, "refresh-1")
        XCTAssertTrue(relaunched.hasParentSession)
    }

    func testKidDeviceTokenSurvivesARelaunch() {
        SessionManager.shared.childDeviceToken = "device-1"
        SessionManager.shared.activeChildId = "child-1"

        let relaunched = SessionManager()

        XCTAssertEqual(relaunched.childDeviceToken, "device-1")
        XCTAssertEqual(relaunched.activeChildId, "child-1")
        XCTAssertTrue(relaunched.hasChildSession)
    }

    func testRelaunchOpensStraightIntoTheParentApp() {
        SessionManager.shared.parentAccessToken = "access-1"
        SessionManager.shared.parentRefreshToken = "refresh-1"
        SessionManager.shared.childDeviceToken = nil
        let d = UserDefaults.standard
        d.set(true, forKey: RootView.Saved.parent)
        d.set(AppMode.parent.rawValue, forKey: RootView.Saved.mode)

        let saved = RootView.savedSession()

        XCTAssertTrue(saved.parent)
        XCTAssertEqual(saved.mode, .parent, "a relaunch should skip the Parent/Child picker")
    }

    func testReinstalledKidPhoneGoesBackToTheKidSide() {
        // A reinstall wipes UserDefaults but the Keychain keeps the token.
        SessionManager.shared.parentAccessToken = nil
        SessionManager.shared.parentRefreshToken = nil
        SessionManager.shared.childDeviceToken = "device-1"
        let d = UserDefaults.standard
        for key in [RootView.Saved.mode, RootView.Saved.parent, RootView.Saved.child] {
            d.removeObject(forKey: key)
        }

        XCTAssertEqual(RootView.savedSession().mode, .tablet)
    }

    func testSignOutForgetsEverythingAfterARelaunch() {
        SessionManager.shared.parentAccessToken = "access-1"
        SessionManager.shared.parentRefreshToken = "refresh-1"
        // What sign-out does to the tokens (clear() also erases the local
        // database, which these tests leave alone).
        SessionManager.shared.parentAccessToken = nil
        SessionManager.shared.parentRefreshToken = nil

        XCTAssertFalse(SessionManager().hasParentSession)
    }

    // MARK: - After a while (the access token expires)

    func testExpiredAccessTokenIsRefreshedAndTheRequestRetried() async throws {
        signIn(access: jwt(expiresIn: 3600), refresh: "refresh-1")
        let fresh = jwt(expiresIn: 3600)
        var calls = 0
        StubProtocol.handler = { request in
            if request.url!.path == "/auth/refresh" {
                return (200, #"{"access_token": "\#(fresh)", "refresh_token": "refresh-2"}"#)
            }
            calls += 1
            // The server has stopped accepting the old token.
            return calls == 1 ? (401, #"{"detail": "Token expired"}"#) : (200, "[]")
        }

        _ = try await APIClient.shared.fetchChildren()

        XCTAssertEqual(SessionManager.shared.parentAccessToken, fresh)
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-2")
        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(KeychainStore.get("parentRefresh"), "refresh-2",
                       "the new refresh token must be saved, or the next launch uses a spent one")
    }

    func testTokenAboutToExpireIsRefreshedBeforeTheRequest() async throws {
        signIn(access: jwt(expiresIn: 30), refresh: "refresh-1")
        let fresh = jwt(expiresIn: 3600)
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh"
                ? (200, #"{"access_token": "\#(fresh)", "refresh_token": "refresh-2"}"#)
                : (200, "[]")
        }

        _ = try await APIClient.shared.fetchChildren()

        let paths = StubProtocol.requests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/auth/refresh", "/children"])
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(fresh)")
    }

    func testServerOutageDuringRefreshKeepsTheParentSignedIn() async {
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh"
                ? (503, #"{"detail": "Sign-in is unavailable for a moment. Try again."}"#)
                : (401, #"{"detail": "Token expired"}"#)
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0, "an outage must not sign anyone out")
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-1")
        XCTAssertTrue(SessionManager().hasParentSession)
    }

    func testRateLimitedRefreshKeepsTheParentSignedIn() async {
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh" ? (429, "{}") : (401, "{}")
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-1")
    }

    func testNoNetworkKeepsTheParentSignedIn() async {
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        StubProtocol.failWith = URLError(.notConnectedToInternet)

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-1")
    }

    func testRefusedRefreshTokenSignsOut() async {
        // The one case that should end the session: the server says the
        // refresh token itself is no good.
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh"
                ? (401, #"{"detail": "Invalid Refresh Token: Already Used"}"#)
                : (401, #"{"detail": "Token expired"}"#)
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 1)
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        // Refresh tokens are single-use: two refreshes with the same one
        // would get the second refused and sign the parent out.
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        let fresh = jwt(expiresIn: 3600)
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh"
                ? (200, #"{"access_token": "\#(fresh)", "refresh_token": "refresh-2"}"#)
                : (200, "[]")
        }

        async let a = APIClient.shared.fetchChildren()
        async let b = APIClient.shared.fetchChildren()
        async let c = APIClient.shared.fetchChildren()
        _ = try await (a, b, c)

        let refreshes = StubProtocol.requests.filter { $0.url!.path == "/auth/refresh" }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(expiredNotices, 0)
    }

    func testReadsExpiryFromTheAccessToken() {
        let token = jwt(expiresIn: 600)
        let expiry = try? XCTUnwrap(APIClient.expiry(ofJWT: token))
        XCTAssertEqual(expiry?.timeIntervalSinceNow ?? 0, 600, accuracy: 5)
        XCTAssertNil(APIClient.expiry(ofJWT: "not-a-jwt"))
    }

    // MARK: - Helpers

    private func signIn(access: String, refresh: String) {
        SessionManager.shared.childDeviceToken = nil
        SessionManager.shared.parentAccessToken = access
        SessionManager.shared.parentRefreshToken = refresh
    }

    /// An unsigned token with only the `exp` claim, which is all the app reads.
    private func jwt(expiresIn seconds: TimeInterval) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let exp = Int(Date().timeIntervalSince1970 + seconds)
        return "\(b64(#"{"alg":"none"}"#)).\(b64(#"{"exp":\#(exp),"n":"\#(UUID())"}"#)).sig"
    }
}

/// Answers the app's requests in tests, and records them.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var failWith: Error?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { handler = nil; failWith = nil; requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, failure): (((URLRequest) -> (Int, String))?, Error?) = Self.lock.withLock {
            Self.requests.append(request)
            return (Self.handler, Self.failWith)
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, body) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
