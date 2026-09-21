import SwiftUI

struct KidTask: Identifiable {
    var occurrenceId: String?
    let id: String
    var title: String
    var iconTaskId: String
    // Optional — a task doesn't have to have a deadline. nil tasks sit in
    // the Ring's "anytime" cluster instead of on the clock face.
    var due: String?
    var done: Bool
    var desc: String
    // Set when the kid taps "Can't do it today?" on TaskDetailView instead
    // of submitting a photo — mirrors the parent-side ChildTask.state ==
    // .bypass concept, but this prototype's kid/parent data are separate
    // mock arrays with no cross-device sync, so it only drives this task's
    // own row/detail styling, not the parent app's review queue.
    var bypassRequested: Bool = false
    var bypassNote: String? = nil
    var bypassHasVoiceNote: Bool = false
    // What actually got submitted for a normal (non-bypass) completion —
    // lets a kid reopen an already-done task and see their own photos and
    // note again, instead of that evidence vanishing the moment
    // TaskDetailView's local capture state is thrown away on dismiss.
    var submittedPhotoCount: Int = 0
    var submissionNote: String? = nil
    var submissionHasVoiceNote: Bool = false
    // Submitting sets done + pendingApproval together — `done` alone used
    // to mean "fully finished," but a parent still needs to look at it, the
    // same review beat the parent-side TaskStore tracks with
    // ChildTask.state == .review. `approved` is what a parent tapping
    // Approve (ScreenProfile/TaskReviewDeck) would flip; there's no live
    // cross-device sync in this prototype (see bypassRequested above), so
    // it's set by hand on demo tasks rather than actually wired to the
    // parent side's review action.
    var pendingApproval: Bool = false
    var approved: Bool = false
    // Mirrors the parent-side TaskReviewDeckView compose step's
    // redoNote/redoHasVoiceNote — a parent asking for a redo instead of
    // approving puts the task back in "to do" territory (not done, not
    // struck through) rather than leaving it looking finished, with a
    // small banner explaining why so the kid isn't just guessing.
    var redoRequested: Bool = false
    var redoNote: String? = nil
    var redoHasVoiceNote: Bool = false
}

extension KidTask {
    // Best-effort "missed" check for the demo's fixed `due` strings (e.g.
    // "6:30 PM") — parses it as *today's* clock time. Good enough to drive
    // the AI coach's goal_missed trigger without a real due-date model.
    var isOverdue: Bool {
        guard !done, let due else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let time = formatter.date(from: due) else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: time)
        guard let dueToday = cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: Date()) else { return false }
        return Date() > dueToday
    }
}

struct HowToGuide: Identifiable {
    let id: String
    var emoji: String
    var title: String
    var blurb: String
    var count: Int
}

enum TabletData {
    static var tasks: [KidTask] = []

    // Used by ScreenTabletHome's task rows to render each task's icon.
    static func sfIcon(for taskId: String) -> String {
        switch taskId {
        case "t1": return "bed.double.fill"
        case "t2": return "function"
        case "t3": return "pawprint.fill"
        case "t4": return "book.fill"
        case "t5": return "mouth.fill"
        case "t6": return "sparkles"
        case "t7": return "pianokeys"
        default: return "star.fill"
        }
    }

    // Real tasks (created via chat, the "+" flow, or Calendar) don't carry
    // one of the fixed demo ids sfIcon(for:) above understands — every one
    // of them fell through to the same plain star. This guesses a more
    // specific icon from the task's own title instead, for the common
    // chores a family actually types, and only falls back to the star
    // placeholder for anything it doesn't recognize. Ordered
    // specific-phrase-first so e.g. "wash the dishes" doesn't get caught
    // by a more generic "wash"-style rule before the dish-specific one.
    // A parent/kid picking a real icon explicitly (tasks.icon, reserved on
    // the backend for that) is meant to take priority over this guess
    // whenever that picker exists — this is the sensible default until then.
    private static let titleIconRules: [(keywords: [String], icon: String)] = [
        (["dish", "dishes", "plate"], "fork.knife"),
        (["laundry"], "washer.fill"),
        (["clothes", "clothing", "fold"], "tshirt.fill"),
        (["bed", "tidy", "room"], "bed.double.fill"),
        (["trash", "garbage", "recycl"], "trash.fill"),
        (["homework", "study", "math", "read"], "book.fill"),
        (["teeth", "floss", "brush"], "mouth.fill"),
        (["dog", "cat", "pet", "feed"], "pawprint.fill"),
        (["plant", "garden", "water"], "leaf.fill"),
        (["shower", "bath"], "drop.fill"),
        (["piano", "practice", "instrument", "music"], "pianokeys"),
        (["backpack", "school bag", "pack bag"], "backpack.fill"),
        (["grocery", "groceries", "shopping"], "basket.fill"),
        (["box", "declutter", "organize"], "shippingbox.fill"),
        (["car"], "car.fill"),
        (["bike", "bicycle"], "bicycle"),
        (["walk", "run", "jog", "exercise"], "figure.walk"),
        (["call", "phone"], "phone.fill"),
        (["draw", "paint", "art"], "paintpalette.fill"),
        (["write", "journal", "diary"], "pencil"),
        (["vacuum", "sweep", "mop", "clean"], "sparkles"),
    ]

    static func guessedIcon(forTitle title: String) -> String {
        let lower = title.lowercased()
        for rule in titleIconRules where rule.keywords.contains(where: { lower.contains($0) }) {
            return rule.icon
        }
        return "star.fill"
    }

    static let howToGuides: [HowToGuide] = [
        HowToGuide(id: "boat", emoji: "⛵", title: "Origami Sailboat", blurb: "Fold a paper boat in 6 steps", count: 6),
        HowToGuide(id: "crane", emoji: "🕊️", title: "Origami Paper Crane", blurb: "The classic lucky paper bird", count: 6),
        HowToGuide(id: "airplane", emoji: "✈️", title: "Classic Paper Airplane", blurb: "A speedy dart that flies far", count: 6),
    ]

    // Asset names are Guide{OrigamiBoat|OrigamiCrane|PaperAirplane}Panel{1-6}.
    static func guidePanelImage(_ guide: HowToGuide, step: Int) -> String {
        let prefix: String
        switch guide.id {
        case "boat": prefix = "GuideOrigamiBoat"
        case "crane": prefix = "GuideOrigamiCrane"
        case "airplane": prefix = "GuidePaperAirplane"
        default: prefix = "GuideOrigamiBoat"
        }
        return "\(prefix)Panel\(step + 1)"
    }
}
