import SwiftUI

struct FamilyPerson: Identifiable {
    let id: String
    var name: String
    var color: Color
    var bg: Color
}

enum CalTaskState { case pending, submitted, done }

struct CalEvent: Identifiable, Equatable {
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
    // A kid's own plan, and where it stands with the parent.
    var isKidPlan: Bool = false
    var planStatus: PlanStatus = .approved
    var reviewNote: String? = nil
}

enum PlanStatus: String {
    case approved, proposed, declined
}

struct CalDayEvent: Identifiable {
    var id = UUID()
    var event: CalEvent
    var day: Int
    var originDay: Int
    var isRecurring: Bool
}

enum CalendarData {
    /// Every real child, live: the calendar's lanes and the task/event "For"
    /// picker. Evlin keeps the children's calendars only, so there's no
    /// parent lane and no family-wide one. MainActor because it reads
    /// FamilyStore.
    @MainActor static var people: [FamilyPerson] {
        FamilyStore.children.map {
            FamilyPerson(id: $0.id, name: $0.name, color: $0.color, bg: $0.color.opacity(0.15))
        }
    }

    // dataYear/dataMonth are the *displayed* month, which
    // AppSync.loadCalendarMonth moves. todayYear/todayMonth/dataDay are the
    // real date, read from the clock every time: an app left open past
    // midnight moves on to the new day (DayClock moves the calendar too).
    private static let gregorian = Calendar(identifier: .gregorian)
    static var todayYear: Int { gregorian.component(.year, from: Date()) }
    static var todayMonth: Int { gregorian.component(.month, from: Date()) }
    static var dataDay: Int { gregorian.component(.day, from: Date()) }
    static var dataYear = gregorian.component(.year, from: Date())
    static var dataMonth = gregorian.component(.month, from: Date())
    static var daysInDataMonth: Int {
        var c = DateComponents(); c.year = dataYear; c.month = dataMonth; c.day = 1
        guard let firstOfMonth = gregorian.date(from: c) else { return 30 }
        return gregorian.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
    }

    /// Whether the displayed month is the real current month — dataDay only
    /// means "today" while this holds; otherwise a day numerically equal to
    /// dataDay is just some other month's same-numbered day.
    static var isDisplayingCurrentMonth: Bool { dataYear == todayYear && dataMonth == todayMonth }

    /// The day a calendar should show once the date moves from `old` to
    /// `new`: the new today if it was on the old one, or if the month
    /// moved on under it; otherwise where it was.
    static func followingToday(_ selected: Int, from old: Date, to new: Date) -> Int {
        guard isDisplayingCurrentMonth else { return selected }
        let monthMoved = !gregorian.isDate(old, equalTo: new, toGranularity: .month)
        let wasOnToday = selected == gregorian.component(.day, from: old)
        return monthMoved || wasOnToday ? dataDay : selected
    }

    static func date(day: Int, minutes: Int = 0) -> Date {
        var c = DateComponents(); c.year = dataYear; c.month = dataMonth; c.day = day
        c.hour = minutes / 60; c.minute = minutes % 60
        return gregorian.date(from: c) ?? Date()
    }

    /// Short weekday name ("Sun"…"Sat") for each day of the displayed month.
    /// Computed (not a stored `let`) since dataYear/dataMonth can now change.
    static var dayNames: [Int: String] {
        let key = monthKey(dataYear, dataMonth)
        if let cached = dayNamesCache, cached.key == key { return cached.names }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var out: [Int: String] = [:]
        for d in 1...daysInDataMonth {
            out[d] = names[gregorian.component(.weekday, from: date(day: d)) - 1]
        }
        dayNamesCache = (key, out)
        return out
    }
    // Worked out once per displayed month: the calendar looks names up
    // inside loops over every day and every item, and building the month
    // afresh on each lookup made a rebuild of the screens take tens of ms.
    private static var dayNamesCache: (key: String, names: [Int: String])?
    static let fullDayNames: [String: String] = [
        "Sun": "Sunday", "Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday",
        "Thu": "Thursday", "Fri": "Friday", "Sat": "Saturday",
    ]
    static var monthShort: String { String(monthFull[dataMonth - 1].prefix(3)) }

    static let allDayCodes = "sun,mon,tue,wed,thu,fri,sat"
    static let weekdayCodes = "mon,tue,wed,thu,fri"

    /// The displayed month, from the phone's database (TaskStore.calendar).
    @MainActor static var eventsByDay: [Int: [CalEvent]] { TaskStore.shared.calendar }

    /// Which children have something on each day, per month ("2026-10"),
    /// kept from every month that has been loaded, so the month picker can
    /// show dots for a month other than the one loaded now.
    static var monthDots: [String: [Int: [String]]] = [:]

    static func monthKey(_ year: Int, _ month: Int) -> String { "\(year)-\(month)" }

    /// Records the loaded month's dots (call after eventsByDay changes).
    @MainActor static func rememberMonthDots() {
        var dots: [Int: [String]] = [:]
        for day in 1...daysInDataMonth {
            var ids: [String] = []
            for de in expandedEvents(for: day, in: eventsByDay) where !ids.contains(de.event.personId) {
                ids.append(de.event.personId)
            }
            if !ids.isEmpty { dots[day] = ids }
        }
        monthDots[monthKey(dataYear, dataMonth)] = dots
    }

    // The child with this id, or "Unknown" (say, a removed child's
    // leftover event), never someone else.
    @MainActor static func person(_ id: String) -> FamilyPerson {
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
