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
}

struct ApiEvent: Codable {
    let id: String
    // Every event is one child's: Evlin keeps the children's calendars only.
    // Optional only so a server still holding an old parent or family-wide
    // event (before the migration that removes them) can't fail the whole
    // list; AppSync skips those.
    let childId: String?
    let title: String
    let startAt: String
    let endAt: String
    let locationOrLink: String?
    let source: String
    let category: String?
    let note: String?
    let recurrence: String
    // Optional so an older server (before kids' plans) still decodes.
    let createdBy: String?
    let status: String?
    let reviewNote: String?
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
}

struct ApiChild: Codable {
    let id: String
    let name: String
    let colorIndex: Int
    let isPaired: Bool
    /// IANA zone this child's device last reported; nil until it has.
    let timezone: String?
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
    // "draft_task" | "draft_event" | "ask_follow_up" | nil — the list lives
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

// MARK: - Today's videos

/// One channel in a child's video settings. `id` is YouTube's channel id,
/// which is what filtering matches; the title is for display.
struct ApiVideoChannel: Codable, Hashable {
    let id: String
    let title: String
}

/// What a child's videos may be. A child with nothing saved gets the
/// server's defaults (every category allowed).
struct ApiVideoProfile: Codable {
    let childId: String
    var allowedCategories: [String]
    var blockedKeywords: [String]
    var allowedChannels: [ApiVideoChannel]
    var blockedChannels: [ApiVideoChannel]
    var dailyMinutes: Int
    var maxVideoMinutes: Int
    /// Every category there is, in display order — from the server so the
    /// chips match what it filters by.
    let allCategories: [String]
}

/// One video on a child's list for today. Only a parent's approval puts
/// one here; the child's player plays nothing else.
struct ApiVideoQueueItem: Codable, Identifiable, Hashable {
    let id: String
    let childId: String
    let localDate: String
    let position: Int
    let videoId: String
    let title: String
    let channelId: String?
    let channelTitle: String?
    let thumbnailUrl: String?
    let durationSeconds: Int
    let category: String?
    let watchedSeconds: Int
    let completedAt: String?

    var isDone: Bool { completedAt != nil }
}

/// Today's list plus how much of the daily allowance is left — computed by
/// the server from what was watched, on every read.
struct ApiVideoQueue: Codable {
    let childId: String
    let localDate: String
    let dailyMinutes: Int
    let watchedSeconds: Int
    let remainingSeconds: Int
    let items: [ApiVideoQueueItem]
}

/// One suggestion on the chat's video card, as the server found and
/// filtered it. Arrives JSON-encoded in the message's `videos` tool arg,
/// because every tool arg is a string on the wire.
struct VideoSuggestion: Codable, Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelId: String
    let channelTitle: String
    let thumbnailUrl: String
    let durationSeconds: Int
    let category: String
    let why: String

    var id: String { videoId }

    static func decodeList(_ raw: String?) -> [VideoSuggestion] {
        guard let data = raw?.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([VideoSuggestion].self, from: data)) ?? []
    }
}
