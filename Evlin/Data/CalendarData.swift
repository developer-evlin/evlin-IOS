import SwiftUI

struct FamilyPerson: Identifiable {
    let id: String
    var name: String
    var color: Color
    var bg: Color
}

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
    static let people: [FamilyPerson] = [
        FamilyPerson(id: "family", name: "Parent", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE")),
        FamilyPerson(id: "child", name: "Child", color: Color(hex: "2563EB"), bg: Color(hex: "DBEAFE")),
    ]

    static let everyone = FamilyPerson(id: "everyone", name: "Family", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))

    static let dataMonth = 9
    static let dataYear = 2024
    static let dataDay = 12
    static let daysInDataMonth = 30

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

    static let allDayCodes = "sun,mon,tue,wed,thu,fri,sat"
    static let weekdayCodes = "mon,tue,wed,thu,fri"

    static let eventsByDay: [Int: [CalEvent]] = [:]

    static let allDayByDay: [Int: [(personId: String, title: String)]] = [:]

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
