import Foundation

struct ChildEvent: Identifiable {
    let id = UUID()
    var time: String
    var end: String
    var title: String
    var emoji: String
    var type: String
}

enum ChildEventsData {
    static let events: [String: [ChildEvent]] = [:]
}
