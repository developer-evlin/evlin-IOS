import Foundation

struct ApiTask: Codable {
    let id: String
    let title: String
    let instructions: String?
    let recurrence: String
    let gatesApps: Bool
    let points: Int
    let submissionKind: String
    let bucket: String
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
    let bedtimeEnabled: Bool
    let bedtimeStart: String?
    let bedtimeEnd: String?
}

struct ApiChildState: Codable {
    let manualLock: Bool
    let taskGateOverride: Bool
}

struct ApiChild: Codable {
    let id: String
    let name: String
    let colorIndex: Int
}
