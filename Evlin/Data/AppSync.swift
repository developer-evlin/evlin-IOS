import Foundation
import SwiftUI
import Observation

/// FamilyStore and TaskStore are plain statics, so SwiftUI has no way to know
/// a sync just rewrote them. Views that show synced data read `version` in
/// their body; every successful sync bumps it, which re-renders them.
@MainActor @Observable
final class SyncState {
    static let shared = SyncState()
    var version = 0
}

@MainActor
class AppSync {
    static let shared = AppSync()

    // Coalesces rapid calls — if a sync is already in flight, new callers
    // await the same task instead of firing duplicate network chains.
    private var inflightSync: Task<Void, Never>?

    // Call this when the app starts or comes foreground, and after onboarding finishes
    func syncBackendData() async {
        if let existing = inflightSync {
            await existing.value
            return
        }
        let task = Task { await _syncBackendData() }
        inflightSync = task
        await task.value
        inflightSync = nil
    }

    private func _syncBackendData() async {
        do {
            let apiChildren = try await APIClient.shared.fetchChildren()

            // If backend is empty (no kids paired/created), nothing to sync yet
            guard !apiChildren.isEmpty else {
                print("AppSync: No child found on backend yet.")
                return
            }

            var syncedChildren: [Child] = []
            var apiTasksByChild: [String: [ApiTask]] = [:]

            for (index, apiChild) in apiChildren.enumerated() {
                let existing = FamilyStore.children.first(where: { $0.id == apiChild.id })
                do {
                    let (child, tasks) = try await syncChild(apiChild, index: index, existing: existing)
                    syncedChildren.append(child)
                    apiTasksByChild[apiChild.id] = tasks
                } catch {
                    // One child failing must not drop them from the UI.
                    print("AppSync: child \(apiChild.id) failed: \(error.localizedDescription)")
                    if let existing { syncedChildren.append(existing) }
                }
            }

            // The backend is the source of truth for who is in the family —
            // this also clears the placeholder child onboarding adds locally
            // before the real one exists.
            FamilyStore.children = syncedChildren
            if SessionManager.shared.activeChildId == nil
                || !syncedChildren.contains(where: { $0.id == SessionManager.shared.activeChildId }) {
                SessionManager.shared.activeChildId = syncedChildren.first?.id
            }

            await syncCalendar(children: syncedChildren, tasks: apiTasksByChild)

            SyncState.shared.version += 1
            print("AppSync: Successfully synced backend data into UI state!")
        } catch {
            print("AppSync Failed: \(error.localizedDescription)")
        }
    }

    // MARK: - One child

    private func syncChild(_ apiChild: ApiChild, index: Int, existing: Child?) async throws -> (Child, [ApiTask]) {
        let id = apiChild.id
        let rules = try await APIClient.shared.fetchRules(childId: id)
        let state = try await APIClient.shared.fetchState(childId: id)
        let apiTasks = try await APIClient.shared.fetchTasks(childId: id)
        let apiOccurrences = try await APIClient.shared.fetchOccurrences(childId: id)

        // Map Tasks/Occurrences -> UI `ChildTask`
        var uiTasks: [ChildTask] = []
        for task in apiTasks {
            let occurrence = apiOccurrences.first(where: { $0.taskId == task.id })

            let uiState: TaskState
            switch occurrence?.status {
            case "approved": uiState = .done
            case "submitted": uiState = .review
            default: uiState = .pending // includes rejected: goes back to the kid
            }

            // The backend only creates an occurrence on days a task actually
            // applies, so no occurrence today means "not today" — park its
            // due date on the next day it does apply so it stays off
            // today's list (ScreenProfile hides tasks due on another day).
            var dueDate: Date? = nil
            var dueLabel: String? = nil
            if occurrence == nil {
                dueDate = CalendarSync.nextOccurrence(of: task, after: Date())
            } else if let time = CalendarSync.parseTime(task.dueTime) {
                dueDate = CalendarSync.date(on: Date(), minutes: time)
                dueLabel = CalendarSync.clock(minutes: time)
            }

            uiTasks.append(ChildTask(
                id: task.id,
                occurrenceId: occurrence?.id,
                title: task.title,
                state: uiState,
                category: task.bucket,
                description: task.instructions ?? "",
                note: occurrence?.bypassNote,
                dueLabel: dueLabel,
                dueDate: dueDate,
                photoCount: task.submissionKind == "photo" ? 1 : 0,
                repeats: CalendarSync.repeatCodes(task.recurrence)
            ))
        }
        TaskStore.binding(for: id).wrappedValue = uiTasks

        // Map Rules. Custom rules only ever exist locally (chat creates them),
        // so keep those; the two backend-backed ones are rebuilt.
        var childRules: [ChildRule] = existing?.rules.filter { $0.kind == .custom } ?? []
        var backendRules: [ChildRule] = [ChildRule(
            id: "screen-time-limit",
            kind: .screenTimeLimit,
            icon: "sf:hourglass",
            title: "Screen Time Limit",
            detail: "\(formatMinutes(rules.dailyLimitMinutes)) per day",
            on: true
        )]
        if rules.downtimeEnabled {
            backendRules.append(ChildRule(
                id: "downtime",
                kind: .downtime,
                icon: "dark_mode",
                title: "Downtime",
                detail: "\(rules.downtimeStart ?? "8:00 PM") – \(rules.downtimeEnd ?? "7:00 AM")",
                on: true
            ))
        }
        childRules = backendRules + childRules

        let palette = FamilyStore.childColorPalette
        let color = palette[apiChild.colorIndex % palette.count]

        if let child = existing {
            child.name = apiChild.name
            child.color = color
            child.rules = childRules
            child.dailyLimitMin = rules.dailyLimitMinutes
            child.manualLock = state.manualLock
            child.taskGateOverride = state.taskGateOverride
            // Reflect real pairing state: the "1 device" row is only true
            // once a device has actually paired.
            if apiChild.isPaired && child.devices.isEmpty {
                child.devices = FamilyStore.demoDevice(apiChild.name)
            } else if !apiChild.isPaired && !child.devices.isEmpty {
                child.devices = []
            }
            return (child, apiTasks)
        }

        let child = Child(
            id: id, name: apiChild.name, age: 10, dailyLimitMin: rules.dailyLimitMinutes,
            color: color, manualLock: state.manualLock, taskGateOverride: state.taskGateOverride,
            timeLeft: formatMinutes(rules.dailyLimitMinutes), timePct: 100, usageTodayMin: 0,
            subtitle: "No tasks yet",
            devices: apiChild.isPaired ? FamilyStore.demoDevice(apiChild.name) : [],
            rules: childRules
        )
        return (child, apiTasks)
    }

    // MARK: - Calendar

    /// Builds the month's calendar (events + tasks) from backend rows.
    private func syncCalendar(children: [Child], tasks: [String: [ApiTask]]) async {
        let cal = Calendar(identifier: .gregorian)
        let monthStart = CalendarData.date(day: 1)
        let monthEnd = cal.date(byAdding: .day, value: CalendarData.daysInDataMonth, to: monthStart) ?? monthStart

        var byDay: [Int: [CalEvent]] = [:]
        var seenEventIds = Set<String>()

        for child in children {
            // Events: this child's plus family-wide ones (deduped by id).
            do {
                let events = try await APIClient.shared.fetchEvents(childId: child.id, from: monthStart, to: monthEnd)
                for e in events where seenEventIds.insert(e.id).inserted {
                    if let (day, ev) = CalendarSync.calEvent(from: e) { byDay[day, default: []].append(ev) }
                }
            } catch {
                print("AppSync: events for \(child.id) failed: \(error.localizedDescription)")
                return // keep the previous calendar rather than showing a partial one
            }

            // Tasks, using today's state from TaskStore (filled by syncChild).
            let store = TaskStore.tasks(for: child.id)
            for task in tasks[child.id] ?? [] {
                let state = store.first(where: { $0.id == task.id })?.state ?? .pending
                if let (day, ev) = CalendarSync.calEvent(from: task, childId: child.id, todayState: state) {
                    byDay[day, default: []].append(ev)
                }
            }
        }
        CalendarData.eventsByDay = byDay
    }
}

// MARK: - Backend row <-> calendar mapping

enum CalendarSync {
    private static let cal = Calendar(identifier: .gregorian)
    private static let codes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parseISO(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) }

    /// "HH:MM[:SS]" -> minutes since midnight.
    static func parseTime(_ s: String?) -> Int? {
        guard let s else { return nil }
        let p = s.split(separator: ":")
        guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    /// "YYYY-MM-DD" (or a full timestamp) -> that calendar day in local time.
    static func parseDay(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return cal.date(from: c)
    }

    static func date(on day: Date, minutes: Int) -> Date {
        cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    static func clock(minutes: Int) -> String { ChildRule.fmtClock(date(on: Date(), minutes: minutes)) }

    /// The app stores repeats as "none" or comma-joined day codes; the backend
    /// may also say "daily".
    static func repeatCodes(_ recurrence: String) -> String {
        let r = recurrence.lowercased()
        if r == "daily" { return CalendarData.allDayCodes }
        if r.isEmpty || r == "none" { return "none" }
        return r
    }

    private static func weekdayCode(_ date: Date) -> String { codes[cal.component(.weekday, from: date) - 1] }

    /// Mirrors the backend's task_applies_on.
    static func applies(_ task: ApiTask, on day: Date) -> Bool {
        let start = parseDay(task.dueDate) ?? parseDay(task.createdAt) ?? day
        let d = cal.startOfDay(for: day)
        if d < cal.startOfDay(for: start) { return false }
        let r = repeatCodes(task.recurrence)
        if r == "none" { return cal.isDate(d, inSameDayAs: start) }
        return Set(r.split(separator: ",").map(String.init)).contains(weekdayCode(d))
    }

    /// First day after `date` the task applies (looks a year ahead).
    static func nextOccurrence(of task: ApiTask, after date: Date) -> Date {
        for offset in 1...365 {
            if let d = cal.date(byAdding: .day, value: offset, to: date), applies(task, on: d) { return d }
        }
        return cal.date(byAdding: .year, value: 1, to: date) ?? date
    }

    /// Day-of-month a (possibly repeating) item should be filed under in the
    /// displayed month, or nil if it doesn't appear in it. Repeats that began
    /// in an earlier month are filed under their first matching day, so the
    /// calendar's forward expansion covers the rest of the month.
    private static func placement(start: Date, repeats: String) -> Int? {
        let y = cal.component(.year, from: start), m = cal.component(.month, from: start)
        if y == CalendarData.dataYear && m == CalendarData.dataMonth { return cal.component(.day, from: start) }
        let monthStart = CalendarData.date(day: 1)
        guard start < monthStart, repeats != "none" else { return nil }
        let set = Set(repeats.split(separator: ",").map(String.init))
        return (1...CalendarData.daysInDataMonth).first { set.contains((CalendarData.dayNames[$0] ?? "").lowercased()) }
    }

    static func calEvent(from e: ApiEvent) -> (Int, CalEvent)? {
        guard let start = parseISO(e.startAt), let end = parseISO(e.endAt) else { return nil }
        let repeats = repeatCodes(e.recurrence)
        guard let day = placement(start: start, repeats: repeats) else { return nil }
        let category = e.category ?? "Activity"
        var ev = CalEvent(
            personId: e.childId ?? (e.source == "parent" ? "family" : "everyone"),
            title: e.title, emoji: emojiForCalendarCategory(category),
            start: ChildRule.fmtClock(start), end: ChildRule.fmtClock(end),
            category: category, location: e.locationOrLink ?? "", note: e.note ?? "", repeats: repeats
        )
        ev.remoteId = e.id
        if let id = UUID(uuidString: e.id) { ev.id = id }
        return (day, ev)
    }

    static func calEvent(from t: ApiTask, childId: String, todayState: TaskState) -> (Int, CalEvent)? {
        let repeats = repeatCodes(t.recurrence)
        guard let startDay = parseDay(t.dueDate) ?? parseDay(t.createdAt),
              let day = placement(start: startDay, repeats: repeats) else { return nil }
        let minutes = parseTime(t.dueTime)
        let startLabel = minutes.map(clock(minutes:)) ?? "12:00 AM"
        let endLabel = minutes.map { clock(minutes: min($0 + 30, 23 * 60 + 59)) } ?? "12:00 AM"
        var ev = CalEvent(
            personId: childId, title: t.title, emoji: emojiForCalendarCategory("Task"),
            start: startLabel, end: endLabel, category: "Task", location: "",
            note: t.instructions ?? "", repeats: repeats, isAnytime: minutes == nil,
            taskState: todayState == .done ? .done : (todayState == .review ? .submitted : .pending),
            gatesUnlock: t.gatesApps, linkedTaskId: t.id
        )
        ev.remoteId = t.id
        return (day, ev)
    }
}
