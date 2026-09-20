import Foundation

struct Notif: Identifiable {
    let id: Int
    var child: String
    var icon: String
    var title: String
    var body: String
    var time: String
    var unread: Bool
    var taskId: String? = nil
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
    static let notifs: [Notif] = []
}

enum ChildEventsData {
    static let events: [String: [ChildEvent]] = [:]
}
