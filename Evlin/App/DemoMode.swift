import Foundation

/// Debug builds only: started with the `-EvlinDemo` launch argument, the app
/// opens as a parent with a sample family already on the phone and never
/// talks to the server. For trying Home and the review deck on the
/// Simulator without a sign-in. Release builds compile it out (`isOn` is
/// always false there).
enum DemoMode {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-EvlinDemo")
    #else
    static let isOn = false
    #endif

    /// Signs in as a stand-in parent and fills the phone's database: one
    /// child, six tasks today (three to do, one sent in, two done), and a
    /// real family's worth of other tasks and events.
    @MainActor static func seedIfOn() {
        #if DEBUG
        guard isOn else { return }
        SessionManager.shared.parentAccessToken = "demo"
        SessionManager.shared.parentRefreshToken = "demo"
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "evlin.parentOnboarded")
        defaults.set("parent", forKey: "evlin.mode")

        let store = LocalStore.shared
        store.eraseAll()
        let childId = "11111111-1111-4111-8111-111111111111"
        SessionManager.shared.activeChildId = childId
        let rules = ApiChildRule(dailyLimitMinutes: 90, downtimeEnabled: false, downtimeStart: nil, downtimeEnd: nil,
                                 dailyLimitEnabled: true, customRules: [], weeklySchedule: nil)
        let state = ApiChildState(manualLock: false, taskGateOverride: false)
        let today = CalendarSync.isoDay(Date())
        let titles = ["Make the bed", "Read for 20 minutes", "Feed the cat", "Math homework", "Tidy the desk", "Practice piano"]
        let statuses = ["pending", "pending", "pending", "submitted", "approved", "approved"]
        var tasks: [ApiTask] = []
        var occurrences: [ApiOccurrence] = []
        for (i, title) in titles.enumerated() {
            let taskId = String(format: "22222222-2222-4222-8222-%012d", i)
            tasks.append(ApiTask(id: taskId, title: title, instructions: nil, recurrence: "daily", gatesApps: true,
                                 submissionKind: "none", bucket: "anytime", category: "Chore", dueDate: nil,
                                 dueTime: i == 2 ? "18:00:00" : nil,
                                 createdAt: CalendarSync.isoString(Date().addingTimeInterval(Double(-i) * 3600)),
                                 bonusMinutes: 0, createdBy: "parent"))
            occurrences.append(ApiOccurrence(id: String(format: "33333333-3333-4333-8333-%012d", i), taskId: taskId,
                                             childId: childId, dueDate: today, status: statuses[i],
                                             bypassRequested: false, bypassNote: nil, rejectionNote: nil))
        }
        // More tasks on other days and a month of events, so the demo is the
        // size of a real family's data: a small one hid a slow rebuild.
        for i in 6..<55 {
            let taskId = String(format: "22222222-2222-4222-8222-%012d", i)
            tasks.append(ApiTask(id: taskId, title: "Extra task \(i)", instructions: nil, recurrence: ["mon,wed,fri", "none", "tue,thu", "sat,sun"][i % 4], gatesApps: true,
                                 submissionKind: "none", bucket: "anytime", category: "Chore",
                                 dueDate: CalendarSync.isoDay(Date().addingTimeInterval(Double(i - 30) * 86400)),
                                 dueTime: nil, createdAt: CalendarSync.isoString(Date()), bonusMinutes: 0, createdBy: "parent"))
        }
        let events: [ApiEvent] = (0..<12).map { i in
            // Daytime hours, so they're on screen when the day view opens.
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(i - 6) * 86400)
            let start = day.addingTimeInterval(Double(9 + (i % 4) * 2) * 3600)
            return ApiEvent(id: String(format: "44444444-4444-4444-8444-%012d", i), childId: childId, title: "Event \(i)",
                            startAt: CalendarSync.isoString(start), endAt: CalendarSync.isoString(start.addingTimeInterval(i % 2 == 0 ? 5400 : 3600)),
                            locationOrLink: nil, source: "manual", category: "Activity", note: nil,
                            recurrence: i % 3 == 0 ? "mon,wed" : "none", createdBy: "parent", status: "approved", reviewNote: nil)
        }
        store.batch {
            for e in events { store.mirrorEventSaved(e) }
            store.saveChild(ApiChild(id: childId, name: "Mia", colorIndex: 0, isPaired: true, timezone: nil),
                            position: 0, rules: rules, state: state, availableMinutes: 90)
            store.saveTasks(tasks, childId: childId)
            store.saveOccurrences(occurrences, photos: [:], childId: childId, dueDate: today)
            // A second child, so the multi-child layouts can be seen, and
            // out of time for today, so "Time's up" and the extra-time card
            // can be seen.
            let leoId = "55555555-5555-4555-8555-555555555555"
            store.saveChild(ApiChild(id: leoId, name: "Leo", colorIndex: 1, isPaired: true, timezone: nil),
                            position: 1, rules: rules, state: state, availableMinutes: 0)   // out of time
            store.saveTasks([ApiTask(id: "66666666-6666-4666-8666-000000000001", title: "Piano practice", instructions: nil,
                                     recurrence: "daily", gatesApps: true, submissionKind: "none", bucket: "anytime",
                                     category: "Chore", dueDate: nil, dueTime: nil, createdAt: CalendarSync.isoString(Date()),
                                     bonusMinutes: 0, createdBy: "parent")], childId: leoId)
            // Done for today, so all that's left is the time.
            store.saveOccurrences([ApiOccurrence(id: "66666666-6666-4666-8666-100000000001",
                                                 taskId: "66666666-6666-4666-8666-000000000001", childId: leoId,
                                                 dueDate: today, status: "approved", bypassRequested: false,
                                                 bypassNote: nil, rejectionNote: nil)],
                                  photos: [:], childId: leoId, dueDate: today)
            let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
            store.mirrorEventSaved(ApiEvent(id: "77777777-7777-4777-8777-000000000001", childId: leoId, title: "Swim class",
                                            startAt: CalendarSync.isoString(start), endAt: CalendarSync.isoString(start.addingTimeInterval(5400)),
                                            locationOrLink: nil, source: "manual", category: "Sport", note: nil, recurrence: "none",
                                            createdBy: "parent", status: "approved", reviewNote: nil))
        }
        #endif
    }
}
