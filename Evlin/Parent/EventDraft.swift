import Foundation

/// What the model worked out about a calendar event, ready to prefill the
/// Add Event card. Same boundary-parsing job as `TaskDraft`: tool args
/// arrive stringified, real types come out.
struct EventDraft: Equatable {
    var title: String = ""
    var startDate: Date = Date()
    /// Minutes since midnight.
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 10 * 60
    var recurrence: String = "none"
    var note: String = ""

    var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    init(title: String = "", startDate: Date = Date(), startMinutes: Int = 9 * 60,
         endMinutes: Int = 10 * 60, recurrence: String = "none", note: String = "") {
        self.title = title
        self.startDate = startDate
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.recurrence = recurrence
        self.note = note
    }

    init(toolArgs: [String: String]?) {
        let args = toolArgs ?? [:]
        title = args["title"]?.trimmingCharacters(in: .whitespaces) ?? ""
        startDate = TaskDraft.parseDate(args["start_date"]) ?? Date()
        startMinutes = TaskDraft.parseMinutes(args["start_time"]) ?? (9 * 60)
        // An event with no duration would render as a zero-height sliver on
        // the day grid, so fall back to an hour rather than to the start.
        endMinutes = TaskDraft.parseMinutes(args["end_time"]) ?? (startMinutes + 60)
        if endMinutes <= startMinutes { endMinutes = startMinutes + 60 }

        let raw = (args["recurrence"] ?? "none").trimmingCharacters(in: .whitespaces).lowercased()
        recurrence = TaskDraft.isValidRecurrence(raw) ? raw : "none"

        note = args["note"]?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Absolute start/end, combining the chosen day with the chosen times.
    var startsAt: Date {
        Calendar.current.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60,
                              second: 0, of: startDate) ?? startDate
    }

    var endsAt: Date {
        Calendar.current.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60,
                              second: 0, of: startDate) ?? startDate
    }
}
