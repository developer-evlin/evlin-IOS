import SwiftUI

struct FamilyPerson: Identifiable {
    let id: String
    var name: String
    var color: Color
    var bg: Color
}

enum CalTaskState { case pending, submitted, done }

struct CalEvent: Identifiable {
    // Backend rows reuse their own UUID so a re-sync keeps the same identity
    // (open sheets and selections don't reset under the user).
    var id = UUID()
    var remoteId: String? = nil
    var personId: String
    var title: String
    var emoji: String
    var start: String
    var end: String
    var category: String
    var location: String
    var note: String
    var repeats: String
    var isAnytime: Bool = false
    var taskState: CalTaskState = .pending
    var gatesUnlock: Bool = false
    var linkedTaskId: String? = nil
}

struct CalDayEvent: Identifiable {
    var id = UUID()
    var event: CalEvent
    var day: Int
    var originDay: Int
    var isRecurring: Bool
}

enum CalendarData {
    static let parentColor = Color(hex: "7C6FF7")
    static let parentBg = Color(hex: "EDE9FE")

    /// The parent's own calendar lane — a fixed id ("family"), a live name.
    /// MainActor because it reads ParentProfile/FamilyStore, both
    /// MainActor-isolated UI-facing stores; everything else in this enum is
    /// plain data parsing/formatting with no such dependency, so only this
    /// and `people`/`person(_:)` below carry the isolation, not the whole
    /// type.
    @MainActor static var parentPerson: FamilyPerson {
        FamilyPerson(id: "family", name: ParentProfile.shared.displayName, color: parentColor, bg: parentBg)
    }

    /// The parent plus every real child, live — used to build calendar
    /// lanes and the task/event "For" picker. Used to be two hardcoded
    /// entries (a fake "Parent" and a single fake "Child" with the literal
    /// id "child") that never matched any real child's actual id, which is
    /// what silently misfiled every real child's tasks under the parent's
    /// own lane wherever `person(_:)` had to fall back — see its own
    /// comment below.
    @MainActor static var people: [FamilyPerson] {
        [parentPerson] + FamilyStore.children.map {
            FamilyPerson(id: $0.id, name: $0.name, color: $0.color, bg: $0.color.opacity(0.15))
        }
    }

    static let everyone = FamilyPerson(id: "everyone", name: "Family", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))

    // The calendar used to model a single fixed month (the day-of-month Int
    // was its only date key, always the month the app happened to launch
    // in). dataYear/dataMonth are now the *displayed* month, which
    // AppSync.loadCalendarMonth can move — todayYear/todayMonth/dataDay stay
    // fixed to the real current date so "is this actually today" checks
    // don't break once the displayed month can differ from it.
    private static let today = Date()
    private static let gregorian = Calendar(identifier: .gregorian)
    static let todayYear = gregorian.component(.year, from: today)
    static let todayMonth = gregorian.component(.month, from: today)
    static let dataDay = gregorian.component(.day, from: today)
    static var dataYear = todayYear
    static var dataMonth = todayMonth
    static var daysInDataMonth: Int {
        var c = DateComponents(); c.year = dataYear; c.month = dataMonth; c.day = 1
        guard let firstOfMonth = gregorian.date(from: c) else { return 30 }
        return gregorian.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
    }

    /// Whether the displayed month is the real current month — dataDay only
    /// means "today" while this holds; otherwise a day numerically equal to
    /// dataDay is just some other month's same-numbered day.
    static var isDisplayingCurrentMonth: Bool { dataYear == todayYear && dataMonth == todayMonth }

    /// Whether `day` in the displayed month is genuinely today.
    static func isToday(day: Int) -> Bool { isDisplayingCurrentMonth && day == dataDay }

    /// The linked ChildTask ids visible on one day for one person, in the
    /// order they're shown.
    ///
    /// Opening the review deck from a calendar day should page through that
    /// day and nothing else. Derived from the events the day already
    /// rendered rather than re-deciding which tasks fall on a date, so it
    /// can't disagree with what's on screen.
    static func linkedTaskIDs(in dayEvents: [CalDayEvent], personId: String) -> [String] {
        dayEvents
            .filter { $0.event.personId == personId }
            .compactMap { $0.event.linkedTaskId }
    }

    static func date(day: Int, minutes: Int = 0) -> Date {
        var c = DateComponents(); c.year = dataYear; c.month = dataMonth; c.day = day
        c.hour = minutes / 60; c.minute = minutes % 60
        return gregorian.date(from: c) ?? today
    }

    /// Short weekday name ("Sun"…"Sat") for each day of the displayed month.
    /// Computed (not a stored `let`) since dataYear/dataMonth can now change.
    static var dayNames: [Int: String] {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var out: [Int: String] = [:]
        for d in 1...daysInDataMonth {
            out[d] = names[gregorian.component(.weekday, from: date(day: d)) - 1]
        }
        return out
    }
    static let fullDayNames: [String: String] = [
        "Sun": "Sunday", "Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday",
        "Thu": "Thursday", "Fri": "Friday", "Sat": "Saturday",
    ]
    static var monthShort: String { String(monthFull[dataMonth - 1].prefix(3)) }

    static let allDayCodes = "sun,mon,tue,wed,thu,fri,sat"
    static let weekdayCodes = "mon,tue,wed,thu,fri"

    /// Filled by AppSync from the backend (events + tasks); the calendar
    /// reads it instead of owning a local-only copy.
    static var eventsByDay: [Int: [CalEvent]] = [:]

    static let allDayByDay: [Int: [(personId: String, title: String)]] = [:]

    // Used to fall back to people[0] (a hardcoded "Parent") for any id it
    // didn't recognize — since every real child's id is a backend UUID that
    // never matched the two fake entries this array used to hold, that
    // fallback fired on every real child event/task, silently relabeling
    // it as the parent's own (wrong color, wrong name, wrong lane — see the
    // "Anytime tasks, Parent" bug this caused). A genuinely unknown id
    // (e.g. a removed child's leftover event) now reads as unknown instead
    // of impersonating someone real.
    @MainActor static func person(_ id: String) -> FamilyPerson {
        if id == everyone.id { return everyone }
        if id == "family" { return parentPerson }
        if let match = people.first(where: { $0.id == id }) { return match }
        return FamilyPerson(id: id, name: "Unknown", color: EColor.onSurfaceVariant, bg: EColor.surfaceContainerLowest)
    }

    static func minutesSinceMidnight(_ str: String) -> Int {
        let parts = str.split(separator: " ")
        guard parts.count == 2 else { return 0 }
        let hm = parts[0].split(separator: ":")
        guard hm.count == 2, var h = Int(hm[0]), let m = Int(hm[1]) else { return 0 }
        let period = parts[1]
        if period == "PM" && h != 12 { h += 12 }
        if period == "AM" && h == 12 { h = 0 }
        return h * 60 + m
    }

    // A linked task's state is only known for today (that's the one
    // occurrence the app loads), so on any other day it reads as pending
    // rather than borrowing today's "done" for every repeat. Now that the
    // displayed month can move, "today" needs the month check too — day 20
    // of a different month isn't today just because it shares dataDay's
    // number.
    private static func forDay(_ ev: CalEvent, _ day: Int) -> CalEvent {
        let isActualToday = day == dataDay && isDisplayingCurrentMonth
        guard ev.linkedTaskId != nil, !isActualToday else { return ev }
        var e = ev; e.taskState = .pending; return e
    }

    static func expandedEvents(for day: Int, in store: [Int: [CalEvent]]) -> [CalDayEvent] {
        let explicit = (store[day] ?? []).map { CalDayEvent(event: forDay($0, day), day: day, originDay: day, isRecurring: false) }
        var expanded: [CalDayEvent] = []
        for (origin, evs) in store where origin < day {
            for ev in evs {
                let r = ev.repeats
                guard r != "none", !r.isEmpty else { continue }
                let codes = Set(r.split(separator: ",").map(String.init))
                guard let dayCode = dayNames[day]?.lowercased(), codes.contains(dayCode) else { continue }
                let alreadyExplicit = explicit.contains { $0.event.title == ev.title && $0.event.start == ev.start && $0.event.personId == ev.personId }
                if !alreadyExplicit {
                    expanded.append(CalDayEvent(event: forDay(ev, day), day: day, originDay: origin, isRecurring: true))
                }
            }
        }
        return explicit + expanded
    }

    static func monthGrid(year: Int, month: Int) -> [Int?] {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        let cal = Calendar(identifier: .gregorian)
        guard let firstOfMonth = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return [] }
        let weekday = cal.component(.weekday, from: firstOfMonth) // 1 = Sun ... 7 = Sat
        let leading = weekday - 1 // Sunday-first, 0-indexed
        var cells: [Int?] = Array(repeating: nil, count: leading)
        cells += range.map { $0 }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    static let monthFull = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
}

func emojiForCalendarCategory(_ category: String) -> String {
    switch category {
    case "Activity": return "📅"
    case "Lesson": return "📚"
    case "Sport": return "⚽"
    case "Family": return "🏠"
    case "Routine": return "🌙"
    case "Study": return "📐"
    case "Chore": return "🧹"
    case "Task": return "✅"
    default: return "📅"
    }
}
