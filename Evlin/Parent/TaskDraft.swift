import Foundation

/// What the model worked out about a task, ready to prefill the Add Task card.
///
/// Tool args arrive as `[String: String]` — the backend stringifies every
/// value so one numeric field can't fail the decode of an entire chat
/// message — so the numeric and boolean fields are parsed here, once, at the
/// boundary. Everything downstream gets real types.
///
/// This exists because the alternative was flattening the model's structured
/// output into a sentence and re-parsing it with string matching, which
/// silently produced an empty card on every real tool call.
struct TaskDraft: Equatable {
    var title: String = ""
    var instructions: String = ""
    /// "YYYY-MM-DD", or nil for no particular day.
    var dueDate: Date?
    /// Minutes since midnight, or nil for no particular time.
    var dueMinutes: Int?
    /// "none" | "daily" | comma-joined weekday codes — the vocabulary
    /// `tasks.recurrence` already accepts.
    var recurrence: String = "none"
    var gatesApps: Bool = true
    var bonusMinutes: Int = 0

    var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    init(title: String = "", instructions: String = "", dueDate: Date? = nil,
         dueMinutes: Int? = nil, recurrence: String = "none",
         gatesApps: Bool = true, bonusMinutes: Int = 0) {
        self.title = title
        self.instructions = instructions
        self.dueDate = dueDate
        self.dueMinutes = dueMinutes
        self.recurrence = recurrence
        self.gatesApps = gatesApps
        self.bonusMinutes = bonusMinutes
    }

    init(toolArgs: [String: String]?) {
        let args = toolArgs ?? [:]
        title = args["title"]?.trimmingCharacters(in: .whitespaces) ?? ""
        instructions = args["instructions"]?.trimmingCharacters(in: .whitespaces) ?? ""
        dueDate = Self.parseDate(args["due_date"])
        dueMinutes = Self.parseMinutes(args["due_time"])

        // Anything outside the vocabulary the DB accepts is treated as a
        // one-off rather than passed through to fail a CHECK constraint on
        // save.
        let raw = (args["recurrence"] ?? "none").trimmingCharacters(in: .whitespaces).lowercased()
        recurrence = Self.isValidRecurrence(raw) ? raw : "none"

        // Stringified booleans arrive as Python's "True"/"False".
        let gates = (args["gates_apps"] ?? "").lowercased()
        gatesApps = gates.isEmpty ? true : !(gates == "false" || gates == "0")

        bonusMinutes = max(0, Int(args["bonus_minutes"] ?? "") ?? 0)
    }

    /// "YYYY-MM-DD" in the device's own calendar — the same local-day
    /// convention `CalendarSync.isoDay` writes.
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f.date(from: s)
    }

    /// "HH:MM" or "HH:MM:SS" -> minutes since midnight.
    static func parseMinutes(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func isValidRecurrence(_ r: String) -> Bool {
        if r == "none" || r == "daily" || r == "weekly" { return true }
        let codes = Set(["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        let parts = r.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return !parts.isEmpty && parts.allSatisfy { codes.contains($0) }
    }

    /// "HH:MM:SS" for the API, or nil.
    var dueTimeString: String? {
        guard let dueMinutes else { return nil }
        return String(format: "%02d:%02d:00", dueMinutes / 60, dueMinutes % 60)
    }

    /// "YYYY-MM-DD" for the API, or nil.
    var dueDateString: String? {
        guard let dueDate else { return nil }
        return CalendarSync.isoDay(dueDate)
    }
}
