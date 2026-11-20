import SwiftUI

/// A child, as the task form's "For" picker shows them.
struct FamilyPerson: Identifiable {
    let id: String
    var name: String
    var color: Color
    var bg: Color
}

/// The children and the real date. (The calendar and its events were
/// removed, 2026-10-28; what's left here is what tasks use.)
enum CalendarData {
    /// Every real child, live: the task form's "For" picker. MainActor
    /// because it reads FamilyStore.
    @MainActor static var people: [FamilyPerson] {
        FamilyStore.children.map {
            FamilyPerson(id: $0.id, name: $0.name, color: $0.color, bg: $0.color.opacity(0.15))
        }
    }

    // The real date, read from the clock every time: an app left open past
    // midnight moves on to the new day (DayClock).
    private static let gregorian = Calendar(identifier: .gregorian)
    static var todayYear: Int { gregorian.component(.year, from: Date()) }
    static var todayMonth: Int { gregorian.component(.month, from: Date()) }
    static var dataDay: Int { gregorian.component(.day, from: Date()) }

    static let allDayCodes = "sun,mon,tue,wed,thu,fri,sat"
    static let weekdayCodes = "mon,tue,wed,thu,fri"

    static let monthFull = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
}
