import Foundation

/// What the chat agent worked out about blocking an app, ready to prefill the
/// Block card: one app from Evlin's catalog, and how long. Tool args arrive
/// as strings (see TaskDraft); real types come out here. The server has
/// already matched the app to the catalog (tool_calls/draft_app_block.py).
/// Blocks are by time only: the same five lengths as blocking by hand.
struct BlockDraft: Equatable {
    var appId: String?
    var appName: String?
    var length: BlockLength?
    /// For a custom length.
    var customMinutes: Int = 90

    init() {}

    init(toolArgs: [String: String]?) {
        let args = toolArgs ?? [:]
        appId = args["app_id"].flatMap { $0.isEmpty ? nil : $0 }
        appName = args["app_name"].flatMap { $0.isEmpty ? nil : $0 }
        length = args["length"].flatMap(BlockLength.init(rawValue:))
        if let m = Int(args["minutes"] ?? ""), m > 0 { customMinutes = min(1440, max(5, m)) }
    }

    /// "HH:MM" → minutes since midnight. Still needed to read scheduled
    /// blocks made before blocks went by time only (EnforcementState).
    static func clock(_ s: String?) -> Int? {
        let parts = (s ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
