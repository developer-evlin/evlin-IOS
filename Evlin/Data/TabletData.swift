import SwiftUI

struct KidTask: Identifiable {
    var occurrenceId: String?
    let id: String
    var title: String
    var iconTaskId: String
    /// What the kid sees beside the task (ChildTask.shownEmoji).
    var emoji: String = EmojiSuggest.fallback
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
    // What actually got submitted for a normal (non-bypass) completion —
    // lets a kid reopen an already-done task and see their own photos and
    // note again, instead of that evidence vanishing the moment
    // TaskDetailView's local capture state is thrown away on dismiss.
    var submittedPhotoCount: Int = 0
    /// The parent asked for a photo: "All done!" waits for one.
    var needsPhoto: Bool = false
    var submissionNote: String? = nil
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
    // redoNote — a parent asking for a redo instead of
    // approving puts the task back in "to do" territory (not done, not
    // struck through) rather than leaving it looking finished, with a
    // small banner explaining why so the kid isn't just guessing.
    var redoRequested: Bool = false
    var redoNote: String? = nil
    // A parent kept a task the kid asked to skip, and wrote why.
    var skipDeclinedNote: String? = nil
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

enum TabletData {
    static var tasks: [KidTask] = []
}
