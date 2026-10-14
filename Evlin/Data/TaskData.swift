import SwiftUI

enum TaskState: String {
    case done, review, pending, overdue, bypass, bypassed
}

struct ChildTask: Identifiable, Equatable {
    var id: String
    var occurrenceId: String? // Added to support bi-directional API sync
    var title: String
    var state: TaskState
    var category: String
    var description: String
    var note: String?
    var submittedAt: String?
    var dueLabel: String?
    // The actual date behind dueLabel's display string — nil for every
    // pre-seeded mock task here (their dueLabel is hand-authored text like
    // "Yesterday, 5:00 PM" with nothing real backing it), so a nil dueDate
    // always counts as "show it today," matching how those always behaved.
    // Only tasks created through the real New Task flow (which picks from
    // an actual date, not a label) set this, which is what lets a task
    // due tomorrow actually stay off today's list.
    var dueDate: Date? = nil
    // 0 = no photo, 1 = the original single-photo layout, 2+ = a grid —
    // a kid submitting multi-page homework (see Math Practice) photographs
    // each page separately rather than one photo standing in for the
    // whole submission.
    var photoCount: Int = 0
    // The real download URLs behind photoCount, in submission order —
    // always photoURLs.count == photoCount for a synced task; kept as a
    // separate array (rather than deriving photoCount from it) since a
    // couple of call sites set photoCount without ever having real URLs
    // (mock/local-only tasks that never reach the backend).
    var photoURLs: [String] = []
    var repeats: String = "none"
    // What the parent sent back on a Redo, from TaskReviewDeckView's compose
    // step — distinct from `note`, which is the kid's own note about their
    // submission.
    var redoNote: String? = nil
    // A parent said no to the kid's ask to skip, with a note: the task is
    // back on for today, and this is what they wrote.
    var skipDeclinedNote: String? = nil
    /// When the task was made, for the newest-first order.
    var createdAt: Date? = nil
}

extension Array where Element == ChildTask {
    /// Today's order, everywhere today's tasks are listed (Home, the review
    /// deck): ones waiting on the parent first, then the list order below.
    func sortedForReview() -> [ChildTask] {
        sorted { a, b in
            let aReview = a.state == .review, bReview = b.state == .review
            if aReview != bReview { return aReview }
            return ChildTask.listOrder(a, b)
        }
    }

    /// Tomorrow's order: the same list order.
    func sortedForTomorrow() -> [ChildTask] { sorted(by: ChildTask.listOrder) }
}

extension ChildTask {
    /// Tasks without a deadline first, newest first, so a task just added
    /// lands at the top and stays there; then deadlines in time order.
    /// Ties fall back to the name, so the order never shuffles.
    static func listOrder(_ a: ChildTask, _ b: ChildTask) -> Bool {
        let aTimed = a.dueLabel != nil, bTimed = b.dueLabel != nil
        if aTimed != bTimed { return !aTimed }
        if aTimed, let da = a.dueDate, let db = b.dueDate, da != db { return da < db }
        let ca = a.createdAt ?? .distantPast, cb = b.createdAt ?? .distantPast
        if ca != cb { return ca > cb }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}

// Mirrors Evlin_Parent_view/index.html's RULE_TYPES — each kind has a fixed
// icon and builds its own detail line from typed fields.
enum RuleKind: String { case downtime, custom, screenTimeLimit }

struct ChildRule: Identifiable, Equatable {
    let id: String
    var kind: RuleKind
    var icon: String
    var title: String
    var detail: String
    var on: Bool
    var downtimeFrom: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    var downtimeTo: Date = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    static func fmtClock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}

extension ChildTask {
    /// On today's list. A task with no date counts as today; one due on
    /// another day doesn't. The one rule for "today" on the parent side,
    /// so the profile's list and the chat's progress card can't disagree.
    var isDueToday: Bool {
        guard let dueDate else { return true }
        return Calendar.current.isDateInToday(dueDate)
    }
}

/// What the screens show for tasks and the calendar, read from the phone's
/// database (LocalStore) and nowhere else.
///
/// Nothing writes here. Every change, from a tap or from a sync, is written
/// to the database, and each database save rebuilds this from it
/// (`reload`). It's observed, so a screen showing a task redraws the moment
/// that task's row changes: an approval shows on Home at once, not when the
/// next sync lands. SwiftData's `@Query` does the same inside a view; this
/// is that, shared, so code outside views (a child's lock status, the
/// review deck's grouping) reads the same thing.
@MainActor @Observable
final class TaskStore {
    static let shared = TaskStore()

    /// Per child: one entry per task, with today's state.
    private(set) var today: [String: [ChildTask]] = [:]
    /// Per child: every task that applies tomorrow (CalendarSync.applies).
    /// Kept apart from `today`: a daily task belongs to both days.
    private(set) var tomorrow: [String: [ChildTask]] = [:]
    /// The displayed month's calendar (CalendarData.dataYear/dataMonth).
    private(set) var calendar: [Int: [CalEvent]] = [:]

    /// Rebuilds from the database. Only assigns what changed, so a save that
    /// changed nothing on screen redraws nothing.
    func reload() {
        let store = LocalStore.shared
        let todayKey = CalendarSync.isoDay(Date())
        let tasksByChild = store.cachedTasksByChild()
        let occurrences = store.occurrenceRows(dueDate: todayKey)

        var newToday: [String: [ChildTask]] = [:]
        var newTomorrow: [String: [ChildTask]] = [:]
        for (childId, apiTasks) in tasksByChild {
            let rows = occurrences.filter { $0.childId == childId }
            let photos = Dictionary(rows.map { ($0.id, $0.photoURLs) }, uniquingKeysWith: { a, _ in a })
            newToday[childId] = AppSync.makeTasks(apiTasks, occurrences: rows.map(\.apiShape), photos: photos)
            newTomorrow[childId] = CalendarSync.tomorrowTasks(from: apiTasks)
        }
        if newToday != today { today = newToday }
        if newTomorrow != tomorrow { tomorrow = newTomorrow }

        scheduleCalendarRebuild()
    }

    private var calendarRebuildPending = false

    /// The month's calendar is rebuilt just after, not in the same instant:
    /// a tap on Home (a tick, an approval) starts its animation in that
    /// instant, and the calendar isn't on screen there. Several saves in a
    /// row make one rebuild.
    private func scheduleCalendarRebuild() {
        guard !calendarRebuildPending else { return }
        calendarRebuildPending = true
        DispatchQueue.main.async { [self] in
            calendarRebuildPending = false
            rebuildCalendar()
        }
    }

    /// The calendar now, for when it must be current straight away (the
    /// displayed month changed).
    func rebuildCalendar() {
        let store = LocalStore.shared
        let newCalendar = AppSync.buildCalendar(events: store.allCachedEvents(), tasks: store.cachedTasksByChild(), today: today)
        if newCalendar != calendar {
            calendar = newCalendar
            CalendarData.rememberMonthDots()
        }
    }

    static func tasks(for childId: String) -> [ChildTask] { shared.today[childId] ?? [] }

    static func tomorrowTasks(for childId: String) -> [ChildTask] { shared.tomorrow[childId] ?? [] }

    /// A fixed set of a child's tasks, in the given order. Home's review
    /// deck pages through this. The set is fixed when the deck opens, not
    /// re-filtered by state, so approving a task doesn't make it vanish
    /// from under the deck mid-swipe; a deleted one drops out.
    static func tasks(for childId: String, ids: [String]) -> [ChildTask] {
        let all = tasks(for: childId)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    /// Which of today's tasks a review deck opened on `taskId` swipes
    /// through: the completed ones if it's completed; otherwise the ones
    /// still needing something (late, waiting on the parent, to do), in the
    /// order Home lists them. Empty if the task isn't today's.
    static func reviewGroup(for childId: String, startingAt taskId: String) -> [String] {
        let today = tasks(for: childId).filter(\.isDueToday)
        guard let tapped = today.first(where: { $0.id == taskId }) else { return [] }
        let done: (ChildTask) -> Bool = { $0.state == .done || $0.state == .bypassed }
        if done(tapped) { return today.filter(done).map(\.id) }
        let late = today.filter { $0.state == .overdue }
        let waiting = today.filter { $0.state == .review || $0.state == .bypass }
        let toDo = today.filter { $0.state == .pending }
        return (late + waiting + toDo).map(\.id)
    }

    // Takes the raw minutes rather than a whole Child — Child seeds its own
    // `rules` from this in its init, before `self` is fully constructed, so
    // this can't take `child: Child` and read child.dailyLimitMin off it.
    static func rules(dailyLimitMin: Int) -> [ChildRule] {
        [
            // A built-in protection, not something a parent authored — see
            // the `.screenTimeLimit` branch in ScreenSettings' ChildSettingsSheet
            // for why it can be toggled but not edited or deleted.
            ChildRule(id: "screen-time-limit", kind: .screenTimeLimit, icon: "sf:hourglass", title: "Screen Time Limit", detail: "\(formatMinutes(dailyLimitMin)) per day", on: true),
            ChildRule(id: "downtime", kind: .downtime, icon: "dark_mode", title: "Downtime", detail: "8:00 PM – 7:00 AM", on: true),
        ]
    }
}

// Sun-first day-of-week codes, matching the order the day-bubble picker
// displays them in.
let weekDayCodes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
let weekDayInitials = ["S", "M", "T", "W", "T", "F", "S"]

// `task.repeats`/`event.repeats` store a comma-joined, Sun-first list of day
// codes (e.g. "mon,tue,wed,thu,fri") rather than a fixed preset keyword, so
// a parent can pick any combination of days on the bubble picker — this
// turns that raw storage back into a friendly label, recognizing the
// all-7/weekdays/weekends combos as their common names.
func repeatDisplayLabel(_ repeats: String) -> String {
    guard repeats != "none", !repeats.isEmpty else { return "" }
    let days = Set(repeats.split(separator: ",").map(String.init))
    if days.count == 7 { return "Daily" }
    if days == Set(["mon", "tue", "wed", "thu", "fri"]) { return "Weekdays" }
    if days == Set(["sat", "sun"]) { return "Weekends" }
    return weekDayCodes.filter { days.contains($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
}

