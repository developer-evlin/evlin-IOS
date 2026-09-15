import SwiftUI

struct FamilyPerson: Identifiable {
    let id: String
    var name: String
    var color: Color
    var bg: Color
}

// A task's progress toward the parent's own review, distinct from a plain
// event which has no completion concept at all — see the three status
// markers this drives on the day timeline (strikethrough/dot/padlock).
enum CalTaskState { case pending, submitted, done }

struct CalEvent: Identifiable {
    let id = UUID()
    var personId: String
    var title: String
    var emoji: String
    var start: String
    var end: String
    var category: String
    var location: String
    var note: String
    var repeats: String
    // The following three only mean anything when category == "Task" — an
    // ordinary event has no anytime/pending-approval/gating concept. Kept
    // on CalEvent itself (not a parallel CalTask type) so tasks and events
    // stay in the same eventsByDay store and the whole existing add/edit/
    // expand/recurrence pipeline works for both without a second copy.
    //
    // Whether this belongs to the day as a whole (the ANYTIME row) rather
    // than a specific moment on the grid.
    var isAnytime: Bool = false
    var taskState: CalTaskState = .pending
    // Whether this is one of the tasks holding the child's apps locked
    // until a parent approves it — the calendar's actual link to
    // enforcement, not just a to-do list. Most tasks aren't gating.
    var gatesUnlock: Bool = false
    // The real ChildTask (TaskStore.tasks(for:)) this calendar entry
    // stands for, when one exists — the calendar's own task list and the
    // profile's task list are two separate mock stores in this prototype,
    // so title-matching between them is a guess; this is the actual,
    // deterministic link. Tapping a task with this set jumps straight into
    // TaskReviewDeckView at that exact task (see ScreenCalendar's
    // onSelect) instead of landing on the plain profile. Only the seeded
    // demo tasks below set it — a task a parent adds through the "+" flow
    // has no real counterpart to jump to, so it falls back to the profile.
    var linkedTaskId: Int? = nil
}

// A day-in-context view of an event: `day` is which day it's being shown as
// occurring on (a recurring event can be shown on many days), `originDay` is
// where it's actually stored — edits/deletes always act on the origin, while
// display (date label, etc.) uses `day`. `isRecurring` marks a virtual
// occurrence generated from an earlier day's repeat rule rather than an
// explicit entry — mirrors index.html's `_origin`/`_recurring`.
struct CalDayEvent: Identifiable {
    var id = UUID()
    var event: CalEvent
    var day: Int
    var originDay: Int
    var isRecurring: Bool
}

enum CalendarData {
    // Every real lane is an actual person's own profile, the parent's
    // included — "family" is the parent's own id (same "Alex Carter"
    // identity ScreenSettings' account header uses), not a group label.
    // A day-timeline lane exists for each of these, in this order.
    static let people: [FamilyPerson] = [
        FamilyPerson(id: "family", name: "Alex Carter", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE")),
        FamilyPerson(id: "liam", name: "Liam", color: Color(hex: "2563EB"), bg: Color(hex: "DBEAFE")),
        FamilyPerson(id: "maya", name: "Maya", color: Color(hex: "16A34A"), bg: Color(hex: "DCFCE7")),
        FamilyPerson(id: "emma", name: "Emma", color: Color(hex: "F97316"), bg: Color(hex: "FFEDD5")),
    ]

    // The one abstract, non-lane entity: "everyone." An event tagged with
    // this id (Family Lunch, Family Dinner) isn't any single person's —
    // it renders as its own full-width block on the grid instead of
    // competing for a lane, and it's never a column a parent can dim.
    // Kept out of `people` on purpose so it can never leak into a lane
    // list; still offered as a "For" option when creating an event.
    static let everyone = FamilyPerson(id: "everyone", name: "Family", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))

    // Mock "data day" — matches Evlin_Parent_view/index.html's DATA_MONTH/
    // DATA_YEAR/TODAY_DAY: the demo events all live on this one fixed day,
    // consistent with the rest of the app's static demo-data approach.
    static let dataMonth = 9 // September, 1-indexed
    static let dataYear = 2024
    static let dataDay = 12
    static let daysInDataMonth = 30

    // Days 8-11 used to read Mon/Tue/Wed/Thu — each one day ahead of its
    // real September 2024 weekday (day 1 is a real Sunday, so day 8 is a
    // real Sunday too).
    static let dayNames: [Int: String] = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat",
        8: "Sun", 9: "Mon", 10: "Tue", 11: "Wed", 12: "Thu", 13: "Fri", 14: "Sat",
        15: "Sun", 16: "Mon", 17: "Tue", 18: "Wed", 19: "Thu", 20: "Fri", 21: "Sat",
        22: "Sun", 23: "Mon", 24: "Tue", 25: "Wed", 26: "Thu", 27: "Fri", 28: "Sat",
        29: "Sun", 30: "Mon",
    ]
    static let fullDayNames: [String: String] = [
        "Sun": "Sunday", "Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday",
        "Thu": "Thursday", "Fri": "Friday", "Sat": "Saturday",
    ]

    // `repeats` stores a comma-joined, Sun-first list of day codes (see
    // weekDayCodes/repeatDisplayLabel in TaskData.swift) — the same format
    // the task RepeatPicker uses, rather than a fixed preset keyword. Day 12
    // (dataDay) is a Thursday, so a "weekly" mock event repeats on "thu" —
    // the same weekday it originates on, matching the old `(day-origin)%7`
    // rule exactly, just expressed as a day-code set instead of a keyword.
    static let allDayCodes = "sun,mon,tue,wed,thu,fri,sat"
    static let weekdayCodes = "mon,tue,wed,thu,fri"

    static let eventsByDay: [Int: [CalEvent]] = [
        12: [
            CalEvent(personId: "family", title: "Work call", emoji: "💻", start: "09:00 AM", end: "10:00 AM", category: "Activity", location: "", note: "", repeats: weekdayCodes),
            CalEvent(personId: "liam", title: "Clean Table", emoji: "🧹", start: "08:00 AM", end: "08:30 AM", category: "Chore", location: "Kitchen", note: "Wipe down the kitchen table.", repeats: allDayCodes),
            CalEvent(personId: "maya", title: "Piano Practice", emoji: "🎹", start: "10:00 AM", end: "11:30 AM", category: "Lesson", location: "Living Room", note: "Work on the new piece.", repeats: "thu"),
            CalEvent(personId: "everyone", title: "Family Lunch", emoji: "🍽️", start: "12:00 PM", end: "01:00 PM", category: "Family", location: "Dining Room", note: "No devices at the table.", repeats: "none"),
            CalEvent(personId: "liam", title: "Math Practice", emoji: "📐", start: "01:30 PM", end: "02:30 PM", category: "Study", location: "Study Room", note: "Chapter 7 exercises.", repeats: weekdayCodes),
            CalEvent(personId: "emma", title: "Reading Time", emoji: "📚", start: "02:00 PM", end: "03:00 PM", category: "Study", location: "Bedroom", note: "Choose one book.", repeats: allDayCodes),
            CalEvent(personId: "maya", title: "Art Class", emoji: "🎨", start: "03:30 PM", end: "05:00 PM", category: "Lesson", location: "Art Studio", note: "Bring watercolor set.", repeats: "thu"),
            CalEvent(personId: "liam", title: "Soccer Practice", emoji: "⚽", start: "04:00 PM", end: "05:30 PM", category: "Sport", location: "City Park", note: "Don't forget shin guards.", repeats: "thu"),
            CalEvent(personId: "everyone", title: "Family Dinner", emoji: "🍴", start: "06:00 PM", end: "07:00 PM", category: "Family", location: "Dining Room", note: "Everyone helps set the table.", repeats: allDayCodes),
            CalEvent(personId: "emma", title: "Story Time", emoji: "🌙", start: "07:30 PM", end: "08:30 PM", category: "Routine", location: "Bedroom", note: "Two stories max.", repeats: allDayCodes),

            // Tasks — same store, category "Task", told apart on the
            // timeline by isAnytime (ANYTIME row vs a due-time slot on the
            // grid) and taskState/gatesUnlock (strikethrough/dot/padlock).
            // start/end on an anytime task is a nominal placeholder — it's
            // excluded from grid layout entirely, so the value itself is
            // never shown.
            CalEvent(personId: "liam", title: "Make your bed", emoji: "🛏️", start: "12:00 AM", end: "12:00 AM", category: "Task", location: "", note: "", repeats: allDayCodes, isAnytime: true, taskState: .done, linkedTaskId: 1),
            CalEvent(personId: "liam", title: "Clean your room", emoji: "🧹", start: "12:00 AM", end: "12:00 AM", category: "Task", location: "", note: "", repeats: "none", isAnytime: true, taskState: .submitted, linkedTaskId: 2),
            CalEvent(personId: "liam", title: "Homework", emoji: "📓", start: "05:00 PM", end: "05:30 PM", category: "Task", location: "", note: "Finish the worksheet.", repeats: "none", taskState: .pending, gatesUnlock: true, linkedTaskId: 3),
            CalEvent(personId: "maya", title: "Feed the dog", emoji: "🐶", start: "12:00 AM", end: "12:00 AM", category: "Task", location: "", note: "", repeats: allDayCodes, isAnytime: true, taskState: .done, linkedTaskId: 1),
            CalEvent(personId: "maya", title: "Practice piano", emoji: "🎹", start: "07:00 PM", end: "07:30 PM", category: "Task", location: "", note: "15 minutes — scales, then a song.", repeats: "none", taskState: .pending, gatesUnlock: true, linkedTaskId: 3),
            CalEvent(personId: "emma", title: "Reading", emoji: "📚", start: "12:00 AM", end: "12:00 AM", category: "Task", location: "", note: "", repeats: "none", isAnytime: true, taskState: .pending, gatesUnlock: true, linkedTaskId: 5),
        ],
    ]

    static let allDayByDay: [Int: [(personId: String, title: String)]] = [
        12: [("liam", "Wellness Day 🧘")],
    ]

    static func person(_ id: String) -> FamilyPerson {
        if id == everyone.id { return everyone }
        return people.first { $0.id == id } ?? people[0]
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

    // Expands `eventsByDay[day]` (explicit entries) plus any earlier day's
    // recurring event that lands on `day` — ported from index.html's
    // expandedEventsForDay.
    static func expandedEvents(for day: Int, in store: [Int: [CalEvent]]) -> [CalDayEvent] {
        let explicit = (store[day] ?? []).map { CalDayEvent(event: $0, day: day, originDay: day, isRecurring: false) }
        var expanded: [CalDayEvent] = []
        for (origin, evs) in store where origin < day {
            for ev in evs {
                let r = ev.repeats
                guard r != "none", !r.isEmpty else { continue }
                let codes = Set(r.split(separator: ",").map(String.init))
                guard let dayCode = dayNames[day]?.lowercased(), codes.contains(dayCode) else { continue }
                let alreadyExplicit = explicit.contains { $0.event.title == ev.title && $0.event.start == ev.start && $0.event.personId == ev.personId }
                if !alreadyExplicit {
                    expanded.append(CalDayEvent(event: ev, day: day, originDay: origin, isRecurring: true))
                }
            }
        }
        return explicit + expanded
    }

    // Sunday-first month grid — nil cells are leading/trailing blanks.
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
