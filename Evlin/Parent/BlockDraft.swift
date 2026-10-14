import Foundation

/// The starting values for the Block Apps card — the kind of block and its
/// detail. Opened empty from the "Block an app" tile; the parent fills it in.
/// (The assistant doesn't draft blocks: its tools are tasks and calendar.)
struct BlockDraft: Equatable {
    enum Kind: String, CaseIterable {
        case duration, untilTask = "until_task", indefinite, scheduled

        var label: String {
            switch self {
            case .duration: return "For a while"
            case .untilTask: return "Until a task"
            case .indefinite: return "Until I lift it"
            case .scheduled: return "On a schedule"
            }
        }
    }

    struct App: Equatable, Hashable { let id: String; let name: String }

    var kind: Kind = .indefinite
    var apps: [App] = []
    var durationMinutes: Int?
    var untilTaskId: String?
    var days: Set<String> = []           // weekday codes
    var startMinutes: Int?               // minutes since midnight, child-local
    var endMinutes: Int?

    init() {}

    /// "HH:MM" → minutes since midnight.
    static func clock(_ s: String?) -> Int? {
        let parts = (s ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}
