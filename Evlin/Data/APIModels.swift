import Foundation

struct ApiTask: Codable {
    let id: String
    let title: String
    let instructions: String?
    let recurrence: String
    let gatesApps: Bool
    let submissionKind: String
    // `bucket` is a DB time-of-day grouping the server derives from due_time
    // and never trusts from the client — see routers/tasks.py. `category` is
    // the free-form UI label ("Chore", "Study", …).
    let bucket: String
    let category: String?
    let dueDate: String?   // "YYYY-MM-DD"
    let dueTime: String?   // "HH:MM:SS"
    let createdAt: String?
    // Minutes awarded to time_grants once this task's occurrence is
    // approved (0 = no bonus) and who authored the task's content —
    // see evlin-backend's TaskBase.
    let bonusMinutes: Int
    let createdBy: String
    /// The task's emoji (tasks.icon), picked by the chat agent or the
    /// parent; nil means the phone guesses one from the title
    /// (EmojiSuggest).
    var icon: String? = nil
    /// A repeating task's exceptions, as calendars keep them: the days taken
    /// out of it ("This task", "YYYY-MM-DD") and its last day ("This and
    /// following tasks"). The server keeps them on the task
    /// (`tasks.skipped_dates`, `repeat_until`), written by the parent's
    /// cut and split (`ServerSupport.taskSeriesEdits`); every phone's
    /// `CalendarSync.RepeatRule` reads them, as `task_applies_on` does.
    var skippedDates: [String]? = nil
    var repeatUntil: String? = nil
}

struct ApiOccurrence: Codable {
    let id: String
    let taskId: String
    let childId: String
    let dueDate: String
    let status: String
    let bypassRequested: Bool
    let bypassNote: String?
    let rejectionNote: String?
    /// When the kid sent it in; nil if they never did (a parent can still
    /// tick it done themselves).
    var completedAt: String? = nil
}

struct ApiChildRule: Codable {
    let dailyLimitMinutes: Int
    let downtimeEnabled: Bool
    let downtimeStart: String?
    let downtimeEnd: String?
    let dailyLimitEnabled: Bool?
    let customRules: [ApiCustomRule]?
    // Calendar-style override: weekday code ("mon".."sun") -> minutes.
    // nil/absent means "use dailyLimitMinutes every day."
    let weeklySchedule: [String: Int]?
    // The weekdays downtime runs on ("mon".."sun"); nil means every day.
    var downtimeDays: [String]? = nil
    // Each day's own hours, when they differ: "mon" -> {start, end} ("HH:MM").
    var downtimeSchedule: [String: ApiDowntimeHours]? = nil
}

struct ApiDowntimeHours: Codable {
    let start: String
    let end: String
}

struct ApiCustomRule: Codable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let on: Bool
}

struct ApiChildState: Codable {
    let manualLock: Bool
    let taskGateOverride: Bool
    /// Nil from a server that doesn't have it yet.
    var instantUnlock: Bool? = nil
}

struct ApiChild: Codable {
    let id: String
    let name: String
    let colorIndex: Int
    let isPaired: Bool
    /// The paired device has finished its own setup (GET /children). Nil
    /// from a server too old to say, which counts as finished.
    var setupComplete: Bool? = nil
    /// Family Sharing's hand-off between the devices (`FamilySharingHandOff`):
    /// "account_created" or nil.
    var setupStage: String? = nil
    /// The paired device, "ipad" or "iphone"; nil when it paired from an
    /// older build or the server is older (`DeviceKind`).
    var deviceKind: String? = nil
    /// IANA zone this child's device last reported; nil until it has.
    let timezone: String?
}

/// The parent's screen time access code (`POST /access-code`).
struct ApiAccessCode: Codable {
    let code: String
    /// By the server's clock, so a phone whose clock is off counts down right.
    let secondsLeft: Double
    let lifetime: Double
}

struct ApiAccessCodeCheck: Codable {
    let ok: Bool
}

/// One app in Evlin's own catalog. Identified by Evlin's id, never a
/// platform identifier — a block, a child's lockable list and the AI all
/// refer to apps this way.
struct ApiApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let aliases: [String]
    let category: String?
}

struct ApiParent: Codable {
    let id: String
    let email: String
    let name: String?
}

struct ApiSubmission: Codable {
    let id: String
    let occurrenceId: String
    let kind: String
    let status: String
    let downloadUrl: String?
}

// One append-only ledger row — signed (a deduction is negative), never a
// mutable balance. See evlin-backend's TimeGrant/routers/time_grants.py.
struct ApiTimeGrant: Codable {
    let id: String
    let childId: String
    let minutes: Int
    let source: String        // "manual" | "task_bonus" | "ai_agent"
    let reason: String?
    let createdBy: String     // "parent" | "ai_agent" | "system"
    let grantedByParentId: String?
    let sourceRefId: String?
    let creditedDate: String  // "YYYY-MM-DD"
    let createdAt: String
}

struct ApiTimeGrantsSummary: Codable {
    let date: String
    let dailyLimitMinutes: Int
    let grantedMinutes: Int
    let availableMinutes: Int
    let grants: [ApiTimeGrant]
}

struct ApiChatMessage: Codable {
    let id: String
    let childId: String
    /// Which thread this belongs to. Optional because messages written
    /// before threading existed are backfilled server-side, and an older
    /// backend wouldn't send it at all.
    let conversationId: String?
    let role: String        // "user" | "assistant"
    let text: String
    // "draft_task" | "draft_app_block" | "ask_follow_up" | nil — the list lives
    // in evlin-backend/tool_calls/. Older messages can carry tool names that
    // no longer exist; those show as plain text with no card.
    let toolCall: String?
    // Always strings on the wire — the backend coerces numeric tool args
    // before storing precisely so this stays decodable (one raw JSON number
    // here would fail the whole message, and with it the transcript).
    let toolArgs: [String: String]?
    /// "chat" | "youtube": which assistant in the thread wrote it. Nil from
    /// a backend that predates the YouTube agent; treat as "chat".
    let agent: String?
    let createdAt: String
    /// Only on the reply to a sent message: the rest of that reply, in
    /// order, when the parent asked for several things at once — one card
    /// each. Nil from history, where every message is its own row.
    var extraMessages: [ApiChatMessage]? = nil
}

/// One chat thread. The sidebar orders by `updatedAt`, so an active thread
/// rises to the top.
struct ApiChatConversation: Codable, Identifiable {
    let id: String
    let childId: String
    let title: String
    let createdAt: String
    let updatedAt: String

    /// "Today" / "Yesterday" / "Previous 7 Days" / "Older" — computed from
    /// the real timestamp rather than stored, so a thread moves between
    /// buckets as time passes instead of being stamped with one forever.
    var section: String {
        guard let date = CalendarSync.parseISO(updatedAt) else { return "Older" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        return days <= 7 ? "Previous 7 Days" : "Older"
    }

    /// The timestamp as the row shows it: a time for today, a weekday
    /// within the last week, a date beyond that.
    var timeLabel: String {
        guard let date = CalendarSync.parseISO(updatedAt) else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mm a"
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else if (cal.dateComponents([.day], from: date, to: Date()).day ?? 0) <= 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: date)
    }
}

// MARK: - App blocks

/// The server's one answer to what this child's device should be doing now
/// (evlin-backend/policy.py). "Today" and "now" are the child's own.
struct ApiPolicy: Codable, Equatable {
    struct AppRef: Codable, Equatable { let appId: String; let name: String }
    struct BlockedNow: Codable, Equatable {
        let blockId: String
        let appId: String?
        let appName: String
        let kind: String
        let description: String
        let until: String?       // when it ends, if it has a known end
    }
    struct Scheduled: Codable, Equatable {
        let blockId: String
        let appId: String?
        let appName: String
        let days: String         // weekday codes the window starts on
        let start: String        // "HH:MM", child-local
        let end: String
    }
    let childId: String
    let timezone: String
    let localDate: String        // "YYYY-MM-DD" the answer was computed for
    let locked: Bool
    let lockReasons: [String]    // "unfinished_tasks" | "manual_lock"
    let lockApps: [AppRef]
    let blockedNow: [BlockedNow]
    let scheduledBlocks: [Scheduled]
    let dailyLimitEnabled: Bool
    let allowanceMinutes: Int?   // nil when the limit is switched off
    let etag: String
}

struct ApiAppBlock: Codable {
    let id: String
    let childId: String
    /// Evlin's catalog app. nil only for a block written before the catalog
    /// that didn't match any catalog name.
    let appId: String?
    let appName: String
    let blockType: String        // "duration" | "until_task" | "indefinite" | "scheduled"
    let durationMinutes: Int?
    let endsAt: String?
    let untilTaskId: String?
    let scheduleDays: String?    // weekday codes the window starts on
    let scheduleStart: String?   // "HH:MM", the child's local time
    let scheduleEnd: String?
    let resolved: Bool
    let resolvedReason: String?  // "task_approved" | "parent_lifted"
    let createdBy: String
    let createdAt: String
    let resolvedAt: String?
    /// Computed server-side for "now" in the child's timezone:
    /// "active" | "off_window" | "expired" | "lifted" | "done".
    let state: String
    /// "until 'Homework' is approved", "school nights 19:00–07:00".
    let description: String
}
