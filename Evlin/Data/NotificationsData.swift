import Foundation

struct Notif: Identifiable {
    let id: Int
    var child: String
    var icon: String
    var title: String
    var body: String
    var time: String
    var unread: Bool
    var taskId: Int? = nil
}

struct ChildEvent: Identifiable {
    let id = UUID()
    var time: String
    var end: String
    var title: String
    var emoji: String
    var type: String
}

enum NotificationsData {
    static let notifs: [Notif] = [
        Notif(id: 1, child: "liam", icon: "task_alt", title: "Science Project — needs review", body: "Tap to review and approve.", time: "2m ago", unread: true, taskId: 2),
        // No taskId: TaskStore has no "Piano Practice" task for any child
        // (id 2 in the default list is "Science Project") — jumping straight
        // to a same-numbered but wrongly-titled task would be worse than
        // just opening the profile, so this one falls back to that instead.
        Notif(id: 2, child: "maya", icon: "music_note", title: "Piano Practice — needs review", body: "45-min session, clip uploaded.", time: "18m ago", unread: true),
        Notif(id: 6, child: "liam", icon: "priority_high", title: "Walk Dog — overdue", body: "Not checked off since yesterday.", time: "12h ago", unread: true, taskId: 4),
        Notif(id: 7, child: "liam", icon: "schedule", title: "Math Practice — due soon", body: "Due at 6:00 PM today.", time: "30m ago", unread: false, taskId: 3),
        Notif(id: 8, child: "liam", icon: "pan_tool", title: "Bypass requested — Read for 20 minutes", body: "\"Had football practice, home late. Can I double up tomorrow?\"", time: "5m ago", unread: true, taskId: 5),
        Notif(id: 3, child: "liam", icon: "sports_soccer", title: "Soccer Practice", body: "Starts in 30 min at City Park.", time: "1h ago", unread: false),
        Notif(id: 4, child: "emma", icon: "menu_book", title: "Reading Goal Reached", body: "60 minutes today — new best!", time: "2h ago", unread: false),
        Notif(id: 5, child: "family", icon: "dinner_dining", title: "Family Dinner Reminder", body: "In 1 hour.", time: "3h ago", unread: false),
    ]
}

enum ChildEventsData {
    static let events: [String: [ChildEvent]] = [
        "liam": [
            ChildEvent(time: "08:00 AM", end: "08:30 AM", title: "Clean Table", emoji: "🧹", type: "Chore"),
            ChildEvent(time: "01:30 PM", end: "02:30 PM", title: "Math Practice", emoji: "📐", type: "School"),
            ChildEvent(time: "04:00 PM", end: "05:30 PM", title: "Soccer Practice", emoji: "⚽", type: "Activity"),
        ],
        "maya": [
            ChildEvent(time: "10:00 AM", end: "11:30 AM", title: "Piano Practice", emoji: "🎹", type: "Activity"),
            ChildEvent(time: "03:30 PM", end: "05:00 PM", title: "Art Class", emoji: "🎨", type: "Activity"),
        ],
        "emma": [
            ChildEvent(time: "02:00 PM", end: "03:00 PM", title: "Reading Time", emoji: "📚", type: "School"),
            ChildEvent(time: "07:30 PM", end: "08:30 PM", title: "Story Time", emoji: "🌙", type: "Wind-down"),
        ],
    ]
}
