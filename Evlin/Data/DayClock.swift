import UIKit
import Observation

/// Notices the day changing (midnight with the app open, or coming back to
/// it on a new day) and moves the app onto the new day: the calendar to the
/// new month if it was showing the old one, today's lists rebuilt from the
/// phone's database, then a sync. Screens that keep a selected day watch
/// `today` and follow it when they were on the old one.
@MainActor @Observable
final class DayClock {
    static let shared = DayClock()

    private static let gregorian = Calendar(identifier: .gregorian)
    private(set) var today = DayClock.gregorian.startOfDay(for: Date())
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged,
                     UIApplication.significantTimeChangeNotification,
                     UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in DayClock.shared.check() }
            })
        }
    }

    func check() {
        let now = Self.gregorian.startOfDay(for: Date())
        guard now != today else { return }
        let previous = today
        today = now

        let was = Self.gregorian.dateComponents([.year, .month], from: previous)
        if CalendarData.dataYear == was.year && CalendarData.dataMonth == was.month {
            CalendarData.dataYear = CalendarData.todayYear
            CalendarData.dataMonth = CalendarData.todayMonth
        }
        // Yesterday's list was built for yesterday: rebuild from the phone
        // first, so the new day shows even with no connection.
        LocalStore.shared.hydrate()
        guard SessionManager.shared.activeToken != nil else { return }
        Task { await AppSync.shared.syncBackendData() }
    }
}
