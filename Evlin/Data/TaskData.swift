import SwiftUI

enum TaskState: String {
    case done, review, pending, overdue, bypass, bypassed
}

struct ChildTask: Identifiable {
    var id: String
    var occurrenceId: String? // Added to support bi-directional API sync
    var title: String
    var state: TaskState
    var category: String
    var description: String
    var note: String?
    var submittedAt: String?
    var dueLabel: String?
    // The actual date behind dueLabel's display string — nil for every
    // pre-seeded mock task here (their dueLabel is hand-authored text like
    // "Yesterday, 5:00 PM" with nothing real backing it), so a nil dueDate
    // always counts as "show it today," matching how those always behaved.
    // Only tasks created through the real New Task flow (which picks from
    // an actual date, not a label) set this, which is what lets a task
    // due tomorrow actually stay off today's list.
    var dueDate: Date? = nil
    // 0 = no photo, 1 = the original single-photo layout, 2+ = a grid —
    // a kid submitting multi-page homework (see Math Practice) photographs
    // each page separately rather than one photo standing in for the
    // whole submission.
    var photoCount: Int = 0
    // The real download URLs behind photoCount, in submission order —
    // always photoURLs.count == photoCount for a synced task; kept as a
    // separate array (rather than deriving photoCount from it) since a
    // couple of call sites set photoCount without ever having real URLs
    // (mock/local-only tasks that never reach the backend).
    var photoURLs: [String] = []
    var repeats: String = "none"
    // Whether the kid attached a voice note with `note` (e.g. a bypass
    // request explained by voice instead of/along with typing) — mirrors
    // the "Record a voice note" option in TaskDetailView's bypass compose.
    var hasVoiceNote: Bool = false
    // What the parent sent back on a Redo, from TaskReviewDeckView's compose
    // step — distinct from `note`, which is the kid's own note about their
    // submission.
    var redoNote: String? = nil
    var redoHasVoiceNote: Bool = false
}

extension Array where Element == ChildTask {
    /// Tasks a parent actually needs to act on (submitted, awaiting review)
    /// bubble to the top; everything else follows in due-time order, with
    /// no-due-time ("Anytime") tasks sorted after any task with a real
    /// time. Applied once at the source (AppSync) so the task list and the
    /// review deck — which walks this same array by raw index — agree on
    /// one order instead of an arbitrary backend-return order.
    func sortedForReview() -> [ChildTask] {
        sorted { a, b in
            let aReview = a.state == .review, bReview = b.state == .review
            if aReview != bReview { return aReview }
            switch (a.dueDate, b.dueDate) {
            case let (da?, db?): return da < db
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }
}

// Mirrors Evlin_Parent_view/index.html's RULE_TYPES — each kind has a fixed
// icon and builds its own detail line from typed fields.
enum RuleKind: String { case downtime, custom, screenTimeLimit }

struct ChildRule: Identifiable {
    let id: String
    var kind: RuleKind
    var icon: String
    var title: String
    var detail: String
    var on: Bool
    var downtimeFrom: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    var downtimeTo: Date = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()

    static func fmtClock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: date)
    }
}

// Per-child task lists, ported from screen-profile.jsx's hardcoded set
// (originally only your child's — mirrored across kids so every profile has content).
enum TaskStore {
    // Generated once per child, then cached — ScreenProfile and a direct
    // notification-tap-to-TaskReviewDeckView route (see ScreenHome) both
    // need to land on the *same* live task list so an approval made from
    // one path is still there if the other path opens afterward. Without
    // this, each fresh call to the old plain generator handed back a brand
    // new array and any edit made through one route silently vanished the
    // moment the other route read `tasks(for:)` again.
    private static var cache: [String: [ChildTask]] = [:]

    static func tasks(for childId: String) -> [ChildTask] {
        if let cached = cache[childId] { return cached }
        let generated = generate(for: childId)
        cache[childId] = generated
        return generated
    }

    // A real, always-up-to-date Binding into the cache — lets any view read
    // and write the same live array without needing to own a @State copy
    // of its own (which is what used to make ScreenProfile the only place
    // that could ever see or make task edits).
    static func binding(for childId: String) -> Binding<[ChildTask]> {
        Binding(
            get: { tasks(for: childId) },
            set: { cache[childId] = $0 }
        )
    }

    // Every real child (from onboarding, or Settings' "Add a child") starts
    // with no tasks — the old per-id demo branches here (one hand-authored
    // task list per status being showcased) are preserved in git history
    // rather than left as unreachable dead code now that no such ids exist.
    private static func generate(for childId: String) -> [ChildTask] { [] }

    // Takes the raw minutes rather than a whole Child — Child seeds its own
    // `rules` from this in its init, before `self` is fully constructed, so
    // this can't take `child: Child` and read child.dailyLimitMin off it.
    static func rules(dailyLimitMin: Int) -> [ChildRule] {
        [
            // A built-in protection, not something a parent authored — see
            // the `.screenTimeLimit` branch in ScreenSettings' ChildSettingsSheet
            // for why it can be toggled but not edited or deleted.
            ChildRule(id: "screen-time-limit", kind: .screenTimeLimit, icon: "sf:hourglass", title: "Screen Time Limit", detail: "\(formatMinutes(dailyLimitMin)) per day", on: true),
            ChildRule(id: "downtime", kind: .downtime, icon: "dark_mode", title: "Downtime", detail: "8:00 PM – 7:00 AM", on: true),
        ]
    }
}

// Sun-first day-of-week codes, matching the order the day-bubble picker
// displays them in.
let weekDayCodes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
let weekDayInitials = ["S", "M", "T", "W", "T", "F", "S"]

// `task.repeats`/`event.repeats` store a comma-joined, Sun-first list of day
// codes (e.g. "mon,tue,wed,thu,fri") rather than a fixed preset keyword, so
// a parent can pick any combination of days on the bubble picker — this
// turns that raw storage back into a friendly label, recognizing the
// all-7/weekdays/weekends combos as their common names.
func repeatDisplayLabel(_ repeats: String) -> String {
    guard repeats != "none", !repeats.isEmpty else { return "" }
    let days = Set(repeats.split(separator: ",").map(String.init))
    if days.count == 7 { return "Daily" }
    if days == Set(["mon", "tue", "wed", "thu", "fri"]) { return "Weekdays" }
    if days == Set(["sat", "sun"]) { return "Weekends" }
    return weekDayCodes.filter { days.contains($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
}

enum ReflectionStep: String, CaseIterable {
    case video, quiz, write

    var stepNumber: Int { switch self { case .video: 1; case .quiz: 2; case .write: 3 } }
    var title: String { switch self {
        case .video: "Watch a short video"
        case .quiz: "Take the quiz"
        case .write: "Write a reflection"
    } }
    var subtitle: String { switch self {
        case .video: "2 min · Why rest time matters"
        case .quiz: "5 questions · need 4 of 5 to pass"
        case .write: "3+ sentences in their own words"
    } }
    var icon: String { switch self {
        case .video: "play_circle"
        case .quiz: "quiz"
        case .write: "edit_note"
    } }
}

struct QuizQuestion { var q: String; var options: [String]; var correct: Int }

enum ReflectionContent {
    static let videoTitle = "Why rest time matters for your brain"
    static let videoDuration = "2:00"
    static let prompt = "You kept scrolling after time was up. What could you do differently tomorrow?"
    static let quiz: [QuizQuestion] = [
        QuizQuestion(q: "Why does your body need rest time away from screens?", options: ["So your eyes and brain can recover and focus better", "Because screens run out of battery", "So adults can use the TV", "It doesn't really matter"], correct: 0),
        QuizQuestion(q: "What is a healthy thing to do when your screen time ends?", options: ["Hide another device under the bed", "Find something fun offline — draw, read, go outside", "Argue until you get more time", "Wait quietly doing nothing"], correct: 1),
        QuizQuestion(q: "How does not sticking to limits make others feel?", options: ["Proud of you", "Nothing at all", "Worried, because agreements matter", "Happy you broke the rule"], correct: 2),
    ]
}
