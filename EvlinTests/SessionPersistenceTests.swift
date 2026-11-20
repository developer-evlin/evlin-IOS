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

    private let keys = ["parentSession", "parentAccess", "parentRefresh", "childDevice", "activeChild"]
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
        // Every test starts with no session token and no exchange attempt;
        // the session tests opt in.
        SessionManager.shared.parentSessionToken = nil
        APIClient.shared.sessionStartRetryAfter = .distantFuture

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
        s.parentSessionToken = KeychainStore.get("parentSession")
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

    func testSignedInParentWhoLeftSetupPartwayIsNotAskedToSignInAgain() {
        // Signed in, then closed the app before setup finished (no kid
        // paired yet): the next launch goes to the parent side, where
        // onboarding skips the sign-in step, not to the Parent/Child picker.
        SessionManager.shared.parentAccessToken = "access-1"
        SessionManager.shared.parentRefreshToken = "refresh-1"
        SessionManager.shared.childDeviceToken = nil
        let d = UserDefaults.standard
        d.set(false, forKey: RootView.Saved.parent)
        d.removeObject(forKey: RootView.Saved.mode)

        let saved = RootView.savedSession()

        XCTAssertFalse(saved.parent, "setup isn't finished, so not into the app yet")
        XCTAssertEqual(saved.mode, .parent)
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

    func testOutageThatTheLiveServerReportsAs401KeepsTheParentSignedIn() async {
        // The server before the auth.py fix answered any failure to reach
        // Supabase with a 401 carrying the error text.
        signIn(access: jwt(expiresIn: -60), refresh: "refresh-1")
        StubProtocol.handler = { request in
            request.url!.path == "/auth/refresh"
                ? (401, #"{"detail": "Server disconnected without sending a response."}"#)
                : (401, #"{"detail": "Token expired"}"#)
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-1")
    }

    func testKidStaysPairedWhenOneRouteRefusesItsToken() async {
        signInKid()
        StubProtocol.handler = { request in
            request.url!.path == "/device/me" ? (200, "{}") : (401, #"{"detail": "Invalid token"}"#)
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(SessionManager.shared.childDeviceToken, "device-1")
    }

    func testKidStaysPairedWhileOffline() async {
        signInKid()
        StubProtocol.failWith = URLError(.notConnectedToInternet)

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
    }

    func testUnpairedKidDeviceSignsOut() async {
        signInKid()
        StubProtocol.handler = { _ in (401, #"{"detail": "Invalid or revoked device token"}"#) }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 1)
    }

    func testOnlySupabaseRefusalsCountAsARefusedRefreshToken() {
        for refused in ["Invalid Refresh Token: Already Used", "Invalid Refresh Token: Refresh Token Not Found",
                        "Session expired", "User not found"] {
            XCTAssertTrue(APIClient.refreshTokenRefused(refused), refused)
        }
        for outage in [nil, "", "timed out", "Server disconnected without sending a response.",
                       "Sign-in is unavailable for a moment. Try again."] {
            XCTAssertFalse(APIClient.refreshTokenRefused(outage), outage ?? "nil")
        }
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

    func testReadsTheGoogleNameFromTheSignInToken() {
        func token(_ meta: String) -> String {
            func b64(_ s: String) -> String {
                Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            }
            return "\(b64(#"{"alg":"none"}"#)).\(b64(#"{"exp":1,"user_metadata":\#(meta)}"#)).sig"
        }
        XCTAssertEqual(APIClient.name(inJWT: token(#"{"full_name":"Esen Dashnyam","name":"Esen"}"#)), "Esen Dashnyam")
        XCTAssertEqual(APIClient.name(inJWT: token(#"{"name":"Esen"}"#)), "Esen")
        XCTAssertNil(APIClient.name(inJWT: token(#"{"full_name":"  "}"#)), "a blank name isn't a name")
        XCTAssertNil(APIClient.name(inJWT: token("{}")), "email sign-ups carry no name")
        XCTAssertNil(APIClient.name(inJWT: "not-a-jwt"))
    }

    func testReadsExpiryFromTheAccessToken() {
        let token = jwt(expiresIn: 600)
        let expiry = try? XCTUnwrap(APIClient.expiry(ofJWT: token))
        XCTAssertEqual(expiry?.timeIntervalSinceNow ?? 0, 600, accuracy: 5)
        XCTAssertNil(APIClient.expiry(ofJWT: "not-a-jwt"))
    }

    // MARK: - The phone's own session (what keeps a parent signed in)

    func testSignInIsTradedForASessionTokenAndSupabaseTokensAreDropped() async throws {
        signIn(access: jwt(expiresIn: 3600), refresh: "refresh-1")
        APIClient.shared.sessionStartRetryAfter = .distantPast
        StubProtocol.handler = { request in
            request.url!.path == "/auth/session" ? (200, #"{"session_token": "sess-1"}"#) : (200, "[]")
        }

        _ = try await APIClient.shared.fetchChildren()

        let s = SessionManager.shared
        XCTAssertEqual(s.parentSessionToken, "sess-1")
        XCTAssertNil(s.parentAccessToken, "nothing left to renew")
        XCTAssertNil(s.parentRefreshToken)
        XCTAssertEqual(KeychainStore.get("parentSession"), "sess-1")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sess-1")
    }

    func testSessionTokenSurvivesARelaunch() {
        signInWithSession()
        let relaunched = SessionManager()
        XCTAssertEqual(relaunched.parentSessionToken, "sess-1")
        XCTAssertTrue(relaunched.hasParentSession)
        XCTAssertTrue(relaunched.isParent)
    }

    func testSessionTokenIsNeverRefreshed() async throws {
        signInWithSession()
        StubProtocol.handler = { _ in (200, "[]") }

        _ = try await APIClient.shared.fetchChildren()

        XCTAssertEqual(StubProtocol.requests.map { $0.url!.path }, ["/children"])
    }

    func testOneRouteRefusingTheSessionDoesNotSignOut() async {
        signInWithSession()
        StubProtocol.handler = { request in
            request.url!.path == "/auth/me" ? (200, "{}") : (401, "{}")
        }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
        XCTAssertEqual(SessionManager.shared.parentSessionToken, "sess-1")
    }

    func testOutageDoesNotSignOutASessionParent() async {
        signInWithSession()
        StubProtocol.failWith = URLError(.notConnectedToInternet)

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 0)
    }

    func testSignedOutElsewhereEndsTheSession() async {
        // Only the server refusing the session at /auth/me (after Sign out
        // or account deletion) signs the phone out.
        signInWithSession()
        StubProtocol.handler = { _ in (401, #"{"detail": "Signed out on this phone"}"#) }

        _ = try? await APIClient.shared.fetchChildren()

        XCTAssertEqual(expiredNotices, 1)
    }

    func testServerWithoutSessionRouteKeepsSupabaseTokens() async throws {
        signIn(access: jwt(expiresIn: 3600), refresh: "refresh-1")
        APIClient.shared.sessionStartRetryAfter = .distantPast
        StubProtocol.handler = { request in
            request.url!.path == "/auth/session" ? (404, #"{"detail": "Not Found"}"#) : (200, "[]")
        }

        _ = try await APIClient.shared.fetchChildren()

        XCTAssertNil(SessionManager.shared.parentSessionToken)
        XCTAssertEqual(SessionManager.shared.parentRefreshToken, "refresh-1")
        XCTAssertEqual(expiredNotices, 0)
    }

    private func signInWithSession() {
        SessionManager.shared.childDeviceToken = nil
        SessionManager.shared.parentAccessToken = nil
        SessionManager.shared.parentRefreshToken = nil
        SessionManager.shared.parentSessionToken = "sess-1"
    }

    // MARK: - Helpers

    private func signInKid() {
        SessionManager.shared.parentSessionToken = nil
        SessionManager.shared.parentAccessToken = nil
        SessionManager.shared.parentRefreshToken = nil
        SessionManager.shared.childDeviceToken = "device-1"
    }

    /// Signed in on Supabase tokens, against a server that can't issue a
    /// session token (the tests of the Supabase path).
    private func signIn(access: String, refresh: String) {
        APIClient.shared.sessionStartRetryAfter = .distantFuture
        SessionManager.shared.parentSessionToken = nil
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
