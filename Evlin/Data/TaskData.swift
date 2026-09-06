import SwiftUI

enum TaskState: String {
    case done, review, pending, overdue, bypass, bypassed
}

struct ChildTask: Identifiable {
    var id: Int
    var title: String
    var state: TaskState
    var category: String
    var description: String
    var note: String?
    var submittedAt: String?
    var dueLabel: String?
    // 0 = no photo, 1 = the original single-photo layout, 2+ = a grid —
    // a kid submitting multi-page homework (see Math Practice) photographs
    // each page separately rather than one photo standing in for the
    // whole submission.
    var photoCount: Int = 0
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
    // Whether finishing this specific task is one of the things holding the
    // device lock open — not every chore should gate the iPad, and without
    // this a parent has no way to mark "the one that matters" apart from
    // "nice if it happens." Defaults on since most tasks created before this
    // existed were implicitly gating ones.
    var gatesApps: Bool = true
    // Display/ordering + reminder timing only (see TaskTimeOfDay) — never
    // read by the lock/unlock decision, which stays day-scoped, not tied to
    // a time of day.
    var timeOfDay: TaskTimeOfDay = .anytime
    // nil/0 = no points set — collapsed behind More Options in AddTaskSheet,
    // so most tasks simply don't have this rather than defaulting to some
    // arbitrary number.
    var points: Int? = nil
    // Whether a parent needs to review a submission before it counts as
    // done — off lets a kid's own checkmark be the end of it. Defaults to
    // the app's long-standing implicit behavior (every submission lands in
    // Review) so existing tasks' behavior doesn't change under them.
    var requiresApproval: Bool = true
}

// A chore's place in a kid's day — a coarse bucket, not a clock time. Drives
// list ordering and reminder timing only; it's unrelated to due dates or the
// lock/unlock decision, which is day-scoped (see ChildTask.gatesApps).
enum TaskTimeOfDay: String, CaseIterable {
    case morning, afterSchool, evening, anytime

    var label: String {
        switch self {
        case .morning: "Morning"
        case .afterSchool: "After school"
        case .evening: "Evening"
        case .anytime: "Anytime"
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
// (originally only Liam's — mirrored across kids so every profile has content).
enum TaskStore {
    static func tasks(for childId: String) -> [ChildTask] {
        if childId == "alex" {
            return []
        }
        if childId == "ben" {
            return [
                ChildTask(id: 1, title: "Make Bed", state: .done, category: "Chore", description: "Straighten the sheets and pillows.", note: "Done first thing.", submittedAt: "7:30 AM", dueLabel: "Today, 8:00 AM", repeats: "sun,mon,tue,wed,thu,fri,sat"),
                ChildTask(id: 2, title: "Spelling Practice", state: .done, category: "Homework", description: "Write each word 3 times, list on the fridge.", note: "All 10 words done.", submittedAt: "4:05 PM", dueLabel: "Today, 5:00 PM", photoCount: 1, repeats: "mon,tue,wed,thu,fri"),
                ChildTask(id: 3, title: "Feed the Cat", state: .done, category: "Chore", description: "Fill the food and water bowls.", note: "Fed and watered.", submittedAt: "6:15 PM", dueLabel: "Today, 6:30 PM", repeats: "sun,mon,tue,wed,thu,fri,sat"),
                ChildTask(id: 4, title: "Read for 20 minutes", state: .done, category: "Reading", description: "Any book, 20+ minutes.", note: "Finished a whole chapter.", submittedAt: "7:40 PM", dueLabel: "Today, 8:00 PM"),
                ChildTask(id: 5, title: "Practice Piano", state: .done, category: "Chore", description: "15 minutes, scales then one song.", note: "Did scales and Ode to Joy.", submittedAt: "5:30 PM", dueLabel: "Today, 6:00 PM"),
            ]
        }
        if childId == "zoe" {
            return [
                ChildTask(id: 1, title: "Clean Table", state: .done, category: "Chore", description: "Wipe down the table and clear plates.", note: "All done!", submittedAt: "12:42 PM", dueLabel: "Today, 1:00 PM", photoCount: 1, repeats: "sun,mon,tue,wed,thu,fri,sat"),
                ChildTask(id: 2, title: "Math Practice", state: .done, category: "Homework", description: "Questions 1–8, page 24.", note: "Finished before dinner.", submittedAt: "5:10 PM", dueLabel: "Today, 6:00 PM", repeats: "mon,tue,wed,thu,fri"),
                ChildTask(id: 3, title: "Reading Essay", state: .done, category: "Homework", description: "300-word essay on this week's chapter.", note: "Turned in early.", submittedAt: "4:20 PM", dueLabel: "Today, 5:00 PM"),
                ChildTask(id: 4, title: "Walk Dog", state: .done, category: "Chore", description: "Walk around the block, 15+ minutes.", note: "Done with Dad.", submittedAt: "5:45 PM", dueLabel: "Today, 5:00 PM", repeats: "sun,mon,tue,wed,thu,fri,sat"),
                ChildTask(id: 5, title: "Read for 20 minutes", state: .done, category: "Reading", description: "Any book, 20+ minutes.", note: "Read a whole chapter.", submittedAt: "7:00 PM", dueLabel: "Today, 8:00 PM"),
            ]
        }
        return [
            ChildTask(id: 1, title: "Clean Table", state: .done, category: "Chore", description: "Wipe down the table and clear plates.", note: "All done!", submittedAt: "12:42 PM", dueLabel: "Today, 1:00 PM", photoCount: 1, repeats: "sun,mon,tue,wed,thu,fri,sat"),
            ChildTask(id: 2, title: "Science Project", state: .review, category: "Homework", description: "Finish the volcano diagram, page 14. Photo when done.", note: "Took longer than expected.", submittedAt: "3:18 PM", dueLabel: "Today, 4:00 PM", photoCount: 1),
            // Submitted with a photo of each worked page rather than one
            // photo for the whole assignment — the multi-photo grid case
            // (see TaskReviewDeck) most other tasks here don't exercise.
            ChildTask(id: 3, title: "Math Practice", state: .review, category: "Homework", description: "Questions 1–8, page 24. Photo when done.", note: "Did all 8, #6 was tricky.", submittedAt: "5:40 PM", dueLabel: "Today, 6:00 PM", photoCount: 3, repeats: "mon,tue,wed,thu,fri"),
            ChildTask(id: 6, title: "Reading Essay", state: .review, category: "Homework", description: "300-word essay on this week's chapter.", note: "Kept it short like you said.", submittedAt: "4:12 PM", dueLabel: "Today, 5:00 PM"),
            ChildTask(id: 5, title: "Read for 20 minutes", state: .bypass, category: "Reading", description: "Any book, 20+ minutes.", note: "Had football practice, home too late. Can I double up tomorrow?", submittedAt: "7:42 PM", dueLabel: "Today, 8:00 PM", hasVoiceNote: true),
            ChildTask(id: 4, title: "Walk Dog", state: .overdue, category: "Chore", description: "Walk around the block, 15+ minutes.", dueLabel: "Yesterday, 5:00 PM", repeats: "sun,mon,tue,wed,thu,fri,sat"),
        ]
    }

    // Takes the raw minutes rather than a whole Child — Child seeds its own
    // `rules` from this in its init, before `self` is fully constructed, so
    // this can't take `child: Child` and read child.dailyLimitMin off it.
    static func rules(dailyLimitMin: Int) -> [ChildRule] {
        [
            // A built-in protection, not something a parent authored — see
            // the `.screenTimeLimit` branch in ScreenProfile's rulesSection
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
