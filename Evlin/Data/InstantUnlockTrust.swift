import SwiftUI
import UserNotifications

/// How a child earns Instant unlock: a run of days with all their tasks sent in.
/// Kept on the parent's phone, which sees every one. A day counts when
/// everything is sent in; a day that ends with tasks left starts it again; a day
/// with no tasks does neither. Earned, it stays until the parent turns Instant
/// unlock off, which starts the run over.
struct UnlockTrust: Codable, Equatable {
    /// Days in a row it takes to earn.
    static let daysNeeded = 3

    var streak = 0
    var earned = false
    var day: String?
    var hadTasks = false
    var doneToday = false

    var daysLeft: Int { max(0, Self.daysNeeded - streak) }

    /// What the day looks like now. True the moment this earns it.
    mutating func note(day today: String, hasTasks: Bool, allDone: Bool) -> Bool {
        if day != today {
            if day != nil && hadTasks && !doneToday { streak = 0 }
            day = today
            hadTasks = false
            doneToday = false
        }
        guard hasTasks else { return false }
        hadTasks = true
        if allDone && !doneToday {
            doneToday = true
            streak += 1
        } else if !allDone && doneToday {
            // An approval taken back.
            doneToday = false
            streak = max(0, streak - 1)
        }
        guard streak >= Self.daysNeeded, !earned else { return false }
        earned = true
        return true
    }

    /// The parent turned it off: back to complete before play, and a new run.
    /// Today, already counted or not, doesn't count again.
    mutating func revoke() {
        streak = 0
        earned = false
        if hadTasks { doneToday = true }
    }
}

@MainActor
final class UnlockTrustStore: ObservableObject {
    static let shared = UnlockTrustStore()

    @Published private var trust: [String: UnlockTrust] = [:]
    private let defaults: UserDefaults
    private let key = "evlin.unlockTrust"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: UnlockTrust].self, from: data) {
            trust = saved
        }
    }

    func trust(for childId: String) -> UnlockTrust { trust[childId] ?? UnlockTrust() }

    @discardableResult
    func note(childId: String, day: String, hasTasks: Bool, allDone: Bool) -> Bool {
        var t = trust(for: childId)
        let earnedNow = t.note(day: day, hasTasks: hasTasks, allDone: allDone)
        if t != trust[childId] {
            trust[childId] = t
            save()
        }
        return earnedNow
    }

    func revoke(childId: String) {
        var t = trust(for: childId)
        t.revoke()
        trust[childId] = t
        save()
    }

    /// Replaces everything (the Demo app's samples).
    func replaceAll(_ new: [String: UnlockTrust]) {
        trust = new
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trust) { defaults.set(data, forKey: key) }
    }
}

/// Draws nothing. Keeps each child's run up to date as tasks change, and tells
/// the parent the moment one earns Instant unlock.
struct UnlockTrustWatcher: View {
    private var signature: [String] {
        FamilyStore.children.map { child in
            let tasks = TaskStore.tasks(for: child.id)
            return "\(child.id)|\(tasks.count)|\(tasks.filter(Self.isDone).count)|\(CalendarSync.isoDay(Date()))"
        }
    }

    // Sent in is enough: the run doesn't wait on the parent looking at it.
    private static func isDone(_ task: ChildTask) -> Bool { task.state == .done || task.state == .review || task.state == .bypassed }

    var body: some View {
        let _ = SyncState.shared.version
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: signature, initial: true) { _, _ in update() }
    }

    private func update() {
        let today = CalendarSync.isoDay(Date())
        for child in FamilyStore.children {
            let tasks = TaskStore.tasks(for: child.id)
            let earned = UnlockTrustStore.shared.note(childId: child.id, day: today, hasTasks: !tasks.isEmpty,
                                                      allDone: tasks.allSatisfy(Self.isDone))
            if earned && !DemoMode.isBuild { notify(childName: child.name) }
        }
    }

    private func notify(childName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Instant unlock is ready"
        content.body = "\(childName) has completed \(UnlockTrust.daysNeeded) days of routines. You can turn it on in their profile."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }
}
