import UIKit

/// What a device is, as the kid's device says when it pairs ("ipad" or
/// "iphone"), so the parent's phone can say "Mia's iPad" (2026-11-13).
enum DeviceKind {
    @MainActor static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    /// "iPad" or "iPhone" for a kind; nil for one not known.
    static func name(_ kind: String?) -> String? {
        switch kind {
        case "ipad": return "iPad"
        case "iphone": return "iPhone"
        default: return nil
        }
    }
}
