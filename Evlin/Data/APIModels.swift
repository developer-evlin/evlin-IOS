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
    let childId: String?   // nil = family-wide
    let title: String
    let startAt: String
    let endAt: String
    let locationOrLink: String?
    let source: String
    let isParentOnly: Bool
    let category: String?
    let note: String?
    let recurrence: String
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
    let source: String        // "manual" | "task_bonus" | "milestone" | "ai_agent"
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
    let role: String        // "user" | "assistant"
    let text: String
    let toolCall: String?   // "draft_task" | "open_block_picker" | nil
    let toolArgs: [String: String]?
    let createdAt: String
}
