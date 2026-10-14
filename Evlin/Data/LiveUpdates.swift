import Foundation

/// Holds a server-sent-events connection to `/live` open while the app is on
/// screen, and syncs whenever the backend says something changed.
///
/// This replaces the fixed-interval polling loops. The stream carries no
/// data — "changed" only means "sync now" — so this decides *when* AppSync
/// runs, never *what* it fetches. There's no second way for data to arrive
/// that could disagree with a sync.
///
/// Launch and foreground still sync on their own. If the stream can't
/// connect (offline, or a backend without `/live`), the app checks for
/// changes every 15 seconds while it's open instead.
@MainActor
final class LiveUpdates {
    static let shared = LiveUpdates()

    /// Its own session, not APIClient's: that one abandons a request after
    /// 15s without data, and a healthy stream is quiet most of the time.
    /// Here the same setting is the dead-connection watchdog. The server
    /// pings every 20s, so 45s of silence means the connection is gone even
    /// if the socket hasn't noticed yet.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var connection: Task<Void, Never>?

    private static let fallbackInterval: UInt64 = 15

    func start() {
        guard connection == nil, !DemoMode.isOn else { return }
        connection = Task { await run() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }

    private enum Outcome {
        /// Was connected and receiving, then the connection ended.
        case dropped
        /// Never got a stream: offline, server down, no such route.
        case failed
        case unauthorized
    }

    private func run() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            switch await connectOnce() {
            case .dropped:
                // A stream that was working and dropped is normal (a deploy,
                // a network change). Come straight back.
                backoff = 1
            case .unauthorized:
                // A parent's access token lasts about an hour. Signing out on
                // a revoked token is left to the ordinary API requests, which
                // already do it; this only tries to get a fresh one.
                if SessionManager.shared.parentAccessToken != nil,
                   await APIClient.shared.refreshParentToken() == .refreshed {
                    continue
                }
            case .failed:
                // No stream (offline, or a server without /live): check for
                // changes every 15s while the app is open instead, so what
                // the other phone does still arrives. Retrying the stream
                // each time means it takes over the moment it's available.
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: Self.fallbackInterval * 1_000_000_000)
                if Task.isCancelled { return }
                AppSync.shared.syncSoon()
                continue
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 60)
        }
    }

    private func connectOnce() async -> Outcome {
        guard let request = APIClient.shared.liveUpdatesRequest() else { return .failed }
        var connected = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 401 { return .unauthorized }
            guard http.statusCode == 200 else { return .failed }
            connected = true

            for try await line in bytes.lines {
                // The server puts each event's name on its own line, so the
                // name alone is the event. (Blank lines, SSE's terminator,
                // never arrive here — AsyncLineSequence drops them.) "ready"
                // is the catch-up sync: the server sends it only once
                // subscribed, so nothing committed before it can be missed.
                // Pings are ": ping" and match neither.
                if line == "event: ready" || line == "event: changed" {
                    // Not awaited. The stream keeps being read while the sync
                    // runs, so a change that lands mid-sync reaches AppSync
                    // and gets a pass of its own.
                    AppSync.shared.syncSoon()
                }
            }
            return .dropped
        } catch {
            return connected ? .dropped : .failed
        }
    }
}
