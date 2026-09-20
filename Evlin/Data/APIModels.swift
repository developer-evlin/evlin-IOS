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
