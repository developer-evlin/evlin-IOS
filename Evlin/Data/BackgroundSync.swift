import BackgroundTasks
import UIKit

/// Keeps the phone's database current while the app isn't on screen, so the
/// kid's lock and both sides' lists are already right when it opens.
///
/// Two pieces, both standard iOS:
/// - Leaving the app, it asks for the extra seconds iOS allows and uses them
///   to send what's waiting in the outbox and fetch the latest.
/// - A background refresh (BGAppRefreshTask) asks iOS to wake the app now
///   and then for a sync. iOS decides when, from how the phone is used, so
///   it's "every so often", never a guaranteed interval. The live stream
///   and the 15-second check do the rest while the app is open.
enum BackgroundSync {
    static let refreshID = "com.evlin.app.refresh"

    /// Asks for the next wake-up, about 15 minutes out at the earliest.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("BackgroundSync: couldn't schedule a refresh: \(error)") }
    }

    /// The wake-up itself: book the next one, then sync.
    @MainActor static func refresh() async {
        scheduleRefresh()
        guard SessionManager.shared.activeToken != nil else { return }
        DayClock.shared.check()
        await AppSync.shared.syncBackendData()
    }

    /// Going to the background: finish sending, within the time iOS gives.
    @MainActor static func finishPendingWork() {
        guard SessionManager.shared.activeToken != nil else { return }
        let task = BackgroundWork()
        task.begin()
        Task { @MainActor in
            await AppSync.shared.syncBackendData()
            task.end()
        }
    }
}

/// One stretch of extra background time, ended exactly once: by the work
/// finishing, or by iOS when the time runs out.
@MainActor
private final class BackgroundWork {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Send changes") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
