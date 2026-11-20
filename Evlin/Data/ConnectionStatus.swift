import Foundation
import Network
import Observation

/// What the small status pill at the top says about the connection, from
/// two things the app already knows, with no checking of its own: iOS's
/// network monitor (on or off) and the outbox (changes waiting, and
/// whether sending or syncing is failing). Nothing is shown while things
/// work; a short blip (a lift, a tunnel) shows nothing either.
@MainActor
@Observable
final class ConnectionStatus {
    static let shared = ConnectionStatus()

    enum Phase: Equatable {
        /// Online and nothing waiting: nothing shown.
        case fine
        /// No network. `waiting`: changes saved on the phone, not sent yet.
        case offline(waiting: Int)
        /// Online, but sending or syncing keeps failing.
        case unreachable(waiting: Int)
        /// What was waiting has just gone through; shown for a moment.
        case caughtUp
    }

    private(set) var phase: Phase = .fine

    private var online = true
    /// iOS says there's a network (not that the server answers).
    var isOnline: Bool { online }
    private var waiting = 0
    private var serverTrouble = false
    private var monitor: NWPathMonitor?
    private var showLater: Task<Void, Never>?
    private var hideLater: Task<Void, Never>?

    /// How long trouble lasts before the pill appears.
    private static let settle: Duration = .seconds(3)

    func start() {
        guard monitor == nil else { return }
        if DemoMode.offline {
            waiting = 2
            setOnline(false)
            return
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in ConnectionStatus.shared.setOnline(isOnline) }
        }
        m.start(queue: DispatchQueue(label: "evlin.connection"))
        monitor = m
    }

    func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        // Back online: the last failure was the network's, not the server's.
        if isOnline { serverTrouble = false }
        recompute()
    }

    /// The outbox's count of changes waiting to be sent.
    func setWaiting(_ count: Int) {
        guard count != waiting else { return }
        waiting = count
        recompute()
    }

    /// Sending or syncing failed while online (true), or just worked (false).
    func setServerTrouble(_ trouble: Bool) {
        guard trouble != serverTrouble else { return }
        serverTrouble = trouble
        recompute()
    }

    private var problem: Phase? {
        if !online { return .offline(waiting: waiting) }
        if serverTrouble { return .unreachable(waiting: waiting) }
        return nil
    }

    private func recompute() {
        if let problem {
            hideLater?.cancel()
            switch phase {
            case .offline, .unreachable:
                phase = problem   // already showing: keep the count current
            case .fine, .caughtUp:
                guard showLater == nil else { return }
                showLater = Task { @MainActor in
                    try? await Task.sleep(for: Self.settle)
                    guard !Task.isCancelled else { return }
                    showLater = nil
                    if let now = self.problem { phase = now }
                }
            }
        } else {
            showLater?.cancel()
            showLater = nil
            switch phase {
            case .offline(let n), .unreachable(let n):
                // Something was waiting and it's all gone through: say so,
                // briefly. Otherwise just go quiet.
                if n > 0 || waiting > 0 {
                    phase = .caughtUp
                    hideLater = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        phase = .fine
                    }
                } else {
                    phase = .fine
                }
            case .fine, .caughtUp:
                break
            }
        }
    }
}
