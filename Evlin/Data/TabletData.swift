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

struct KidChild {
    let id: String
    var name: String
    var usedMin: Int
    var limitMin: Int
}

enum TabletData {
    static let child = KidChild(id: "liam", name: "Liam", usedMin: 94, limitMin: 120)

    static var tasks: [KidTask] = [
        KidTask(occurrenceId: nil, id: "t1", title: "Make your bed", iconTaskId: "t1", due: "8:00 AM", done: true, desc: "Pull up your covers, fluff your pillow, and put any clothes in the basket.", pendingApproval: false, approved: true),
        KidTask(occurrenceId: nil, id: "t2", title: "Do your maths", iconTaskId: "t2", due: "6:00 PM", done: true, desc: "Complete questions 1 through 8 on page 24 of your maths book.", pendingApproval: false, approved: true),
        KidTask(occurrenceId: nil, id: "t3", title: "Feed Biscuit", iconTaskId: "t3", due: "6:30 PM", done: false, desc: "Give Biscuit one scoop of dry food and fresh water."),
        KidTask(occurrenceId: nil, id: "t4", title: "Read your book", iconTaskId: "t4", due: "7:30 PM", done: false, desc: "Read quietly for at least 20 minutes from your current book."),
        KidTask(occurrenceId: nil, id: "t5", title: "Brush your teeth", iconTaskId: "t5", due: "8:30 PM", done: false, desc: "Brush for two full minutes, top and bottom."),
        // Submitted, waiting on a parent to check it — done from the kid's
        // own side, but not yet approved.
        KidTask(occurrenceId: nil, id: "t6", title: "Tidy your room", iconTaskId: "t6", due: "5:30 PM", done: true, desc: "Put toys back in the bin and clothes in the hamper.", submittedPhotoCount: 1, pendingApproval: true, approved: false),
        // A parent asked for a redo instead of approving — back to normal
        // ("to do") styling, with the redo note visible on the card.
        KidTask(occurrenceId: nil, id: "t7", title: "Practice piano", iconTaskId: "t7", due: "4:00 PM", done: false, desc: "15 minutes, scales then one song.", redoRequested: true, redoNote: "Good start! Can you play it once more with both hands together?", redoHasVoiceNote: false),
        // Plain demo task, no icon chip — now that the task-row icon and
        // the calendar's per-event glyphs are both gone, this is just a
        // fresh example to eyeball the icon-less row/timeline styling on.
        KidTask(occurrenceId: nil, id: "t8", title: "Walk the dog", iconTaskId: "t8", due: "5:00 PM", done: false, desc: "Take Biscuit around the block, at least once around the park."),
    ]

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
