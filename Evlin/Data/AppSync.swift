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
    /// Set when a background save (approve, lock, rule edit, …) fails, so the
    /// UI can tell the user instead of the change silently bouncing back.
    var writeError: String?
    /// Set when a read/sync pass fails — previously this only ever reached
    /// a console `print`, so a parent or kid stuck on stale (or, worse,
    /// placeholder) data had no way to know a real refresh was failing.
    /// Not `writeError`/its alert on purpose: a background poll retries
    /// every foreground and every 15s while a screen is open, so a modal
    /// alert on every failed attempt would be its own kind of broken UX —
    /// this drives a quiet, dismissible banner instead. Cleared the moment
    /// any sync succeeds.
    var syncError: String?
}

/// The signed-in parent's own profile (name), loaded from the backend.
@MainActor @Observable
final class ParentProfile {
    static let shared = ParentProfile()
    /// What the name field edits.
    var name = ""
    /// What the server has, so we only save real changes.
    private(set) var savedName = ""
    private(set) var email = ""

    /// The name to show: the saved one, else the part of the email before the @.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "Parent" : local.capitalized
    }

    func load(_ parent: ApiParent) {
        email = parent.email
        // Don't clobber a name that's mid-edit.
        let editing = name != savedName
        savedName = parent.name ?? ""
        if !editing { name = savedName }
    }

    /// Call when the user finishes editing; saves only if it changed.
    func saveIfChanged() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != savedName else { name = savedName; return }
        name = trimmed
        BackendWrite.run("Your name") { try await APIClient.shared.updateMyName(trimmed) }
    }

    /// Used by onboarding, which wants to know whether the save worked.
    func saveNow(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await APIClient.shared.updateMyName(trimmed)
        savedName = trimmed
        name = trimmed
    }

    func reset() { name = ""; savedName = ""; email = "" }
}

/// Runs a backend write in the background. A failure is reported through
/// `SyncState.writeError`, and either way the app re-syncs so the screen shows
/// what the server actually has.
@MainActor
enum BackendWrite {
    static func run(_ what: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() }
            catch { SyncState.shared.writeError = "\(what) wasn't saved. \(error.apiUserMessage)" }
            await AppSync.shared.syncBackendData()
        }
    }
}

extension Child {
    /// Persists this child's rules (limit, downtime, custom rules) after any local edit.
    func pushRules() {
        let id = self.id
        let body = RuleSync.payload(for: self)
        BackendWrite.run("That rule change") { try await APIClient.shared.saveRules(childId: id, body: body) }
    }
}

enum RuleSync {
    private static func hhmmss(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d:00", c.hour ?? 0, c.minute ?? 0)
    }

    @MainActor static func payload(for child: Child) -> [String: Any] {
        let limit = child.rules.first { $0.kind == .screenTimeLimit }
        let downtime = child.rules.first { $0.kind == .downtime }
        var body: [String: Any] = [
            "daily_limit_minutes": child.dailyLimitMin,
            "daily_limit_enabled": limit?.on ?? true,
            "downtime_enabled": downtime?.on ?? false,
            "custom_rules": child.rules.filter { $0.kind == .custom }.map {
                ["id": $0.id, "title": $0.title, "detail": $0.detail, "icon": $0.icon, "on": $0.on] as [String: Any]
            },
        ]
        if let downtime {
            body["downtime_start"] = hhmmss(downtime.downtimeFrom)
            body["downtime_end"] = hhmmss(downtime.downtimeTo)
        } else {
            body["downtime_clear"] = true
        }
        return body
    }
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

    /// A kid's phone only holds a device token (no parent login), so it syncs
    /// just its own child through the device endpoints.
    private var isKidDevice: Bool {
        SessionManager.shared.parentAccessToken == nil && SessionManager.shared.childDeviceToken != nil
    }

    private func syncKidDevice() async {
        do {
            let me = try await APIClient.shared.fetchMyChild()
            let existing = FamilyStore.children.first(where: { $0.id == me.id })
            let (child, _) = try await syncChild(me, index: 0, existing: existing)
            FamilyStore.children = [child]
            SessionManager.shared.activeChildId = me.id
            SyncState.shared.version += 1
            SyncState.shared.syncError = nil
        } catch {
            print("AppSync (kid) failed: \(error.localizedDescription)")
            SyncState.shared.syncError = "Couldn't refresh. \(error.apiUserMessage)"
        }
    }

    private func _syncBackendData() async {
        if isKidDevice { await syncKidDevice(); return }
        do {
            let apiChildren = try await APIClient.shared.fetchChildren()
            // The parent's own profile doesn't depend on having children yet.
            if let me = try? await APIClient.shared.fetchMe() { ParentProfile.shared.load(me) }

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
                    SyncState.shared.syncError = nil
                } catch {
                    // One child failing must not drop them from the UI. On a
                    // cold launch (fresh install, or the very first sync of
                    // the session) there's no `existing` to fall back to —
                    // that used to mean a single transient failure on any of
                    // syncChild's several sequential requests (rules, state,
                    // tasks, occurrences, per-task submissions) made a real,
                    // fully-paired child vanish into "No child yet," which
                    // then pointed the parent at "Add a child" — exactly the
                    // wrong fix, since the real backend data was never gone.
                    // A bare-bones Child built from just the /children
                    // response (which already succeeded) keeps them visible
                    // with placeholder stats until the next sync — on
                    // foreground or the next poll — fills in the rest.
                    print("AppSync: child \(apiChild.id) failed: \(error.localizedDescription)")
                    SyncState.shared.syncError = "Couldn't fully refresh \(apiChild.name). \(error.apiUserMessage)"
                    syncedChildren.append(existing ?? placeholderChild(apiChild))
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
            SyncState.shared.syncError = "Couldn't refresh. \(error.apiUserMessage)"
        }
    }

    // Moves the calendar to a different month and loads its real data —
    // used when the parent browses the month picker or steps the day nav
    // past the edge of the currently loaded month. Only tasks + events need
    // refetching (rules/state/occurrences are already current from the last
    // full sync; occurrence status only exists for today regardless of
    // which month is on screen — see CalendarData.forDay).
    func loadCalendarMonth(year: Int, month: Int) async {
        CalendarData.dataYear = year
        CalendarData.dataMonth = month
        let children = FamilyStore.children
        var apiTasksByChild: [String: [ApiTask]] = [:]
        for child in children {
            apiTasksByChild[child.id] = (try? await APIClient.shared.fetchTasks(childId: child.id)) ?? []
        }
        await syncCalendar(children: children, tasks: apiTasksByChild)
        SyncState.shared.version += 1
    }

    // MARK: - One child

    /// A child that exists on the backend (the /children call that produced
    /// `apiChild` already succeeded) but whose fuller syncChild fetch just
    /// failed. Built only from what /children already returned, so it's
    /// always safe to show — no rules/tasks/state guessed, just enough to
    /// keep the child on screen instead of disappearing.
    ///
    /// `devices:` used to be left at its default (empty), which showed a
    /// real, still-paired child as "No device — Pair" in Settings any time
    /// this fallback was used (Child.devices is what Settings' deviceRow
    /// actually reads, not a fresh backend check) — `apiChild.isPaired`
    /// already came back true from the same /children call everything
    /// else here is built from, so there's no reason to guess wrong.
    private func placeholderChild(_ apiChild: ApiChild) -> Child {
        let palette = FamilyStore.childColorPalette
        return Child(
            id: apiChild.id, name: apiChild.name, age: 0, dailyLimitMin: 60,
            color: palette[apiChild.colorIndex % palette.count],
            timeLeft: "—", timePct: 100, usageTodayMin: 0,
            subtitle: "Syncing…",
            devices: apiChild.isPaired ? FamilyStore.demoDevice(apiChild.name) : []
        )
    }

    private func syncChild(_ apiChild: ApiChild, index: Int, existing: Child?) async throws -> (Child, [ApiTask]) {
        let id = apiChild.id
        let rules = try await APIClient.shared.fetchRules(childId: id)
        let state = try await APIClient.shared.fetchState(childId: id)
        let apiTasks = try await APIClient.shared.fetchTasks(childId: id)
        let apiOccurrences = try await APIClient.shared.fetchOccurrences(childId: id)
        // Real available-today total (base limit, or a weekly_schedule
        // override for today, plus every grant/deduction) — not just the
        // flat daily limit. Best-effort: a failure here shouldn't fail the
        // whole sync over a number that's secondary to tasks/rules.
        let timeGrants = try? await APIClient.shared.fetchTimeGrants(childId: id)
        // Also best-effort, and for a sharper reason: reflections and app
        // blocks feed the lock, so they have to be cached to stay correct
        // offline — but a fetch failure here must not fail the whole sync,
        // since the previously cached values are still the right answer.
        let reflections = try? await APIClient.shared.fetchReflections(childId: id)
        let appBlocks = try? await APIClient.shared.fetchAppBlocks(childId: id, activeOnly: false)
        let milestones = try? await APIClient.shared.fetchMilestones(childId: id)

        LocalStore.shared.saveTasks(apiTasks, childId: id)
        LocalStore.shared.saveOccurrences(apiOccurrences, childId: id, dueDate: CalendarSync.isoDay(Date()))
        LocalStore.shared.saveChildState(childId: id, childName: apiChild.name, rules: rules, state: state)
        if let timeGrants { LocalStore.shared.saveTimeGrants(timeGrants, childId: id) }
        if let reflections { LocalStore.shared.saveReflections(reflections, childId: id) }
        if let appBlocks { LocalStore.shared.saveAppBlocks(appBlocks, childId: id) }
        if let milestones { LocalStore.shared.saveMilestones(milestones, childId: id) }

        // Map Tasks/Occurrences -> UI `ChildTask`
        var uiTasks: [ChildTask] = []
        for task in apiTasks {
            let occurrence = apiOccurrences.first(where: { $0.taskId == task.id })

            let bypass = occurrence?.bypassRequested ?? false
            let uiState: TaskState
            switch occurrence?.status {
            case "approved": uiState = bypass ? .bypassed : .done
            case "submitted": uiState = .review
            case "rejected": uiState = .pending // a redo: goes back to the kid
            default: uiState = bypass ? .bypass : .pending
            }
            var redoNote: String? = nil
            if occurrence?.status == "rejected" {
                let n = occurrence?.rejectionNote ?? ""
                redoNote = n.isEmpty ? "Please try again." : n
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

            // Real evidence, not a guess from the task's declared kind —
            // that used to read task.submissionKind (what a task is
            // *supposed* to require, which nothing in the UI actually lets
            // a parent set — every task is created with "none") instead of
            // what the kid actually turned in, so a real photo submission
            // always showed the review card's empty "waiting for photo"
            // state no matter what the kid uploaded. Only worth a fetch
            // once there's something to fetch: a pending occurrence has no
            // submissions yet.
            // Same story as photoURLs above, and the same mirrored bug:
            // hasVoiceNote was never set from real data at all here, so a
            // real recorded voice note never showed on the review card
            // either — on top of KidVoiceRecorderButton never having
            // captured real audio in the first place (see TaskDetailView).
            var photoURLs: [String] = []
            var hasVoiceNote = false
            var voiceURL: String? = nil
            if let occId = occurrence?.id, occurrence?.status == "submitted" || occurrence?.status == "approved" {
                let subs = (try? await APIClient.shared.fetchSubmissions(occurrenceId: occId)) ?? []
                photoURLs = subs.filter { $0.kind == "photo" }.compactMap { $0.downloadUrl }
                // A voice submission row can exist before its own upload
                // finishes (downloadUrl only comes back once the backend
                // sees status "uploaded") — hasVoiceNote tracks the row,
                // voiceURL tracks whether it's actually ready to play.
                if let voiceSub = subs.first(where: { $0.kind == "voice" }) {
                    hasVoiceNote = true
                    voiceURL = voiceSub.downloadUrl
                }
            }

            uiTasks.append(ChildTask(
                id: task.id,
                occurrenceId: occurrence?.id,
                title: task.title,
                state: uiState,
                category: task.category ?? task.bucket,
                description: task.instructions ?? "",
                note: occurrence?.bypassNote,
                dueLabel: dueLabel,
                dueDate: dueDate,
                photoCount: photoURLs.count,
                photoURLs: photoURLs,
                repeats: CalendarSync.repeatCodes(task.recurrence),
                hasVoiceNote: hasVoiceNote,
                voiceURL: voiceURL,
                redoNote: redoNote
            ))
        }
        TaskStore.binding(for: id).wrappedValue = uiTasks.sortedForReview()

        // Map Rules — all of them now live on the backend.
        var childRules: [ChildRule] = [ChildRule(
            id: "screen-time-limit",
            kind: .screenTimeLimit,
            icon: "sf:hourglass",
            title: "Screen Time Limit",
            detail: "\(formatMinutes(rules.dailyLimitMinutes)) per day",
            on: rules.dailyLimitEnabled ?? true
        )]
        // The Downtime rule exists once it has times (it can still be switched off).
        if rules.downtimeEnabled || rules.downtimeStart != nil {
            var dt = ChildRule(id: "downtime", kind: .downtime, icon: "dark_mode", title: "Downtime", detail: "", on: rules.downtimeEnabled)
            if let m = CalendarSync.parseTime(rules.downtimeStart) { dt.downtimeFrom = CalendarSync.date(on: Date(), minutes: m) }
            if let m = CalendarSync.parseTime(rules.downtimeEnd) { dt.downtimeTo = CalendarSync.date(on: Date(), minutes: m) }
            dt.detail = "\(ChildRule.fmtClock(dt.downtimeFrom)) – \(ChildRule.fmtClock(dt.downtimeTo))"
            childRules.append(dt)
        }
        for c in rules.customRules ?? [] {
            childRules.append(ChildRule(id: c.id, kind: .custom, icon: c.icon, title: c.title, detail: c.detail, on: c.on))
        }

        let palette = FamilyStore.childColorPalette
        let color = palette[apiChild.colorIndex % palette.count]
        // Real total (base limit, or today's weekly_schedule override, plus
        // every grant/deduction) when the fetch above succeeded; falls back
        // to the flat limit only if it didn't, same as this always showed
        // before time_grants existed — never worse than the old behavior.
        let realTimeLeft = formatMinutes(timeGrants?.availableMinutes ?? rules.dailyLimitMinutes)

        if let child = existing {
            child.name = apiChild.name
            child.color = color
            child.rules = childRules
            child.dailyLimitMin = rules.dailyLimitMinutes
            child.manualLock = state.manualLock
            child.taskGateOverride = state.taskGateOverride
            // Real data now, not a guess — safe to overwrite unconditionally
            // (this also self-heals a placeholderChild's "—" sentinel, which
            // used to be the one special case handled here).
            child.timeLeft = realTimeLeft
            child.timePct = 100
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
            timeLeft: realTimeLeft, timePct: 100, usageTodayMin: 0,
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

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    /// A Date -> "YYYY-MM-DD" in local calendar time, matching what
    /// APIClient.fetchOccurrences already sends as target_date.
    static func isoDay(_ date: Date) -> String { isoDayFormatter.string(from: date) }

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

    /// Exact mirror of the backend's task_applies_on (occurrences.py) — used
    /// both to expand recurring items across the visible calendar month and
    /// (see LocalStore) to self-materialize "today's occurrences" locally
    /// when the device can't reach the server. Keep these two in sync; a
    /// mismatch here silently disagrees with what the server would
    /// generate. Works off task.recurrence directly rather than through
    /// repeatCodes(_:) — that helper collapses "daily" into a fixed 7-code
    /// string for *display* purposes, which happened to still work for
    /// "daily" here (all 7 codes always contain today's) but silently
    /// dropped "weekly" (never expanded into a real weekday match, so a
    /// weekly task never applied on any day at all through this function).
    static func applies(_ task: ApiTask, on day: Date) -> Bool {
        let start = parseDay(task.dueDate) ?? parseDay(task.createdAt) ?? day
        let d = cal.startOfDay(for: day)
        let startDay = cal.startOfDay(for: start)
        let rec = task.recurrence.trimmingCharacters(in: .whitespaces).lowercased()
        if rec.isEmpty || rec == "none" { return cal.isDate(d, inSameDayAs: startDay) }
        // A UTC-anchored created_at fallback (no explicit due_date) can
        // already read as "tomorrow" on a device west of UTC the same
        // evening a task was created — without this slack, a recurring
        // task never gets an occurrence on the day it was actually made.
        // due_date is already an unambiguous calendar date with no UTC
        // conversion involved, so it gets no slack — mirrors
        // task_applies_on's own comment exactly.
        let slackDays = task.dueDate == nil ? 1 : 0
        let boundary = cal.date(byAdding: .day, value: -slackDays, to: startDay) ?? startDay
        if d < boundary { return false }
        if rec == "daily" { return true }
        if rec == "weekly" { return weekdayCode(d) == weekdayCode(startDay) }
        let codes = Set(rec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return codes.contains(weekdayCode(d))
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
            personId: e.childId ?? (e.isParentOnly ? "family" : "everyone"),
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
