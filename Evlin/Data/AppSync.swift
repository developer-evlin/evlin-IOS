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
    /// False until the first sync of this launch has finished, however it
    /// ended. Until then an empty FamilyStore means "not loaded yet", not
    /// "this parent has no child", and Home shows a spinner instead of its
    /// "No child yet" screen.
    var hasFinishedFirstSync = false
    /// True once a sync this launch has put the server's children and tasks
    /// on screen, before the slower calendar and video parts finish. The
    /// splash waits for it, so a launch doesn't flash the saved state.
    var hasFreshChildren = false
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

    private var shown = ""

    /// Redraws the screens that read the family (FamilyStore), if it
    /// changed. A sync that brings back the same data redraws nothing.
    /// Tasks and the calendar don't need this: TaskStore is observed.
    func publish() {
        let now = Self.snapshot()
        guard now != shown else { return }
        shown = now
        version += 1
    }

    private static func snapshot() -> String {
        var out = ""
        for c in FamilyStore.children {
            out += "\(c.id)|\(c.name)|\(c.manualLock)|\(c.taskGateOverride)|\(c.timeLeft)|\(c.dailyLimitMin)|\(c.devices.count)\n"
            for r in c.rules { out += "\(r.id)|\(r.title)|\(r.detail)|\(r.on)\n" }
            for b in LocalStore.shared.cachedAppBlocks(childId: c.id) {
                out += "\(b.id)|\(b.resolved)|\(b.state ?? "")|\(b.summary ?? "")\n"
            }
        }
        return out
    }
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

    // The last name and email the server sent, kept on the phone so the
    // greeting is right from the first frame of a launch instead of reading
    // "Hi, Parent" until /auth/me answers.
    private static let cacheKey = "parentProfile.cache"

    init() {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] {
            savedName = cached["name"] ?? ""
            name = savedName
            email = cached["email"] ?? ""
        }
    }

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
        UserDefaults.standard.set(["name": savedName, "email": email], forKey: Self.cacheKey)
    }

    /// Call when the user finishes editing; saves only if it changed.
    func saveIfChanged() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != savedName else { name = savedName; return }
        name = trimmed
        Outbox.send(APIClient.Write.updateMyName(trimmed), label: "Your name")
    }

    /// Used by onboarding, which wants to know whether the save worked.
    func saveNow(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await APIClient.shared.updateMyName(trimmed)
        savedName = trimmed
        name = trimmed
    }

    func reset() {
        name = ""; savedName = ""; email = ""
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }
}

extension Child {
    /// Persists this child's rules (limit, downtime, custom rules) after any local edit.
    func pushRules() {
        Outbox.send(APIClient.Write.saveRules(childId: id, body: RuleSync.payload(for: self)), childId: id, label: "That rule change")
    }
}

extension Child {
    /// Saves the lock and the task-gate override after a local change.
    func saveState(label: String) {
        LocalStore.shared.mirrorChildState(childId: id, manualLock: manualLock, taskGateOverride: taskGateOverride)
        Outbox.send(APIClient.Write.updateChildState(childId: id, manualLock: manualLock, taskGateOverride: taskGateOverride),
                    childId: id, label: label)
    }
}

enum RuleSync {
    private static func hhmmss(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d:00", c.hour ?? 0, c.minute ?? 0)
    }

    @MainActor static func payload(for child: Child) -> [String: Any] {
        let downtime = child.rules.first { $0.kind == .downtime }
        var body: [String: Any] = [
            "daily_limit_minutes": child.dailyLimitMin,
            // The limit can't be switched off in the app any more; saving
            // any rule also turns back on one switched off before.
            "daily_limit_enabled": true,
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

    /// Set by a caller that arrives while a sync is already running. That
    /// sync may have fetched before whatever the caller is reacting to was
    /// committed, so it isn't enough to just wait for it: one more pass runs
    /// after it. However many callers arrive meanwhile, that's one pass.
    ///
    /// Joining without this handed a live-update "changed" the results of a
    /// sync that started before the change existed — and nothing fetched
    /// again until the next event, which might never come.
    private var rerunRequested = false

    // Call this when the app starts or comes foreground, and after onboarding finishes
    func syncBackendData() async {
        // The debug demo never talks to the server (DemoMode).
        if DemoMode.isOn { SyncState.shared.hasFinishedFirstSync = true; return }
        if let existing = inflightSync {
            rerunRequested = true
            await existing.value
            return
        }
        let task = Task {
            repeat {
                rerunRequested = false
                await _syncBackendData()
            } while rerunRequested
        }
        inflightSync = task
        await task.value
        inflightSync = nil
        SyncState.shared.hasFinishedFirstSync = true
    }

    private var syncSoonPending = false

    /// A sync a moment from now, for live updates: a burst of changes
    /// (approving five tasks is five commits) becomes one sync, not five.
    func syncSoon() {
        guard !syncSoonPending else { return }
        syncSoonPending = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            syncSoonPending = false
            await syncBackendData()
        }
    }

    /// A kid's phone only holds a device token (no parent login), so it syncs
    /// just its own child through the device endpoints.
    private var isKidDevice: Bool {
        SessionManager.shared.parentAccessToken == nil && SessionManager.shared.childDeviceToken != nil
    }

    /// A write queued after a pass started fetching may not be in what it
    /// fetched. Such a pass stops before showing anything and runs again.
    private struct Superseded: Error {}
    private var passGeneration = 0

    private func ensureCurrent(_ generation: Int) throws {
        if Outbox.generation != generation { throw Superseded() }
    }

    /// Sends the outbox first. Returns false while writes are still
    /// waiting: fetching then would bring back the server's older picture
    /// over changes that haven't reached it.
    private func sendPendingWrites() async -> Bool {
        if await Outbox.drain().isEmpty { return true }
        SyncState.shared.syncError = "Your changes will send when you're back online."
        return false
    }

    private func syncKidDevice() async {
        do {
            let me = try await APIClient.shared.fetchMyChild()
            // What "today" and "now" mean for this child on the server — a
            // scheduled block's window, which day a grant lands on. Sent
            // only when it differs, so an unchanged zone never writes.
            let zone = TimeZone.current.identifier
            if me.timezone != zone { _ = try? await APIClient.shared.updateMyDevice(timezone: zone) }
            let existing = FamilyStore.children.first(where: { $0.id == me.id })
            let child = try await syncChild(me, index: 0, existing: existing)
            FamilyStore.children = [child]
            SessionManager.shared.activeChildId = me.id
            SyncState.shared.hasFreshChildren = true
            // The kid's own calendar: their events and tasks for the month.
            await syncCalendar(children: [child], generation: passGeneration)
            await VideoQueueStore.shared.refresh(childId: me.id)
            SyncState.shared.publish()
            SyncState.shared.syncError = nil
        } catch is Superseded {
            rerunRequested = true
        } catch {
            print("AppSync (kid) failed: \(error.localizedDescription)")
            SyncState.shared.syncError = "Couldn't refresh. \(error.apiUserMessage)"
        }
    }

    private func _syncBackendData() async {
        guard await sendPendingWrites() else { return }
        passGeneration = Outbox.generation
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

            for (index, apiChild) in apiChildren.enumerated() {
                let existing = FamilyStore.children.first(where: { $0.id == apiChild.id })
                do {
                    let child = try await syncChild(apiChild, index: index, existing: existing)
                    syncedChildren.append(child)
                    SyncState.shared.syncError = nil
                } catch is Superseded {
                    rerunRequested = true
                    return
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
            LocalStore.shared.keepOnlyChildren(apiChildren.map(\.id))
            if SessionManager.shared.activeChildId == nil
                || !syncedChildren.contains(where: { $0.id == SessionManager.shared.activeChildId }) {
                SessionManager.shared.activeChildId = syncedChildren.first?.id
            }
            SyncState.shared.hasFreshChildren = true

            await syncCalendar(children: syncedChildren, generation: passGeneration)
            for child in syncedChildren { await VideoQueueStore.shared.refresh(childId: child.id) }

            SyncState.shared.publish()
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
    /// Which children have something on each day of a month, from the
    /// tasks' and events' own repeat rules. Doesn't move the calendar's
    /// loaded month: it's for the month picker's dots on any month.
    func monthDots(year: Int, month: Int) async -> [Int: [String]] {
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let first = cal.date(from: c), let days = cal.range(of: .day, in: .month, for: first),
              let end = cal.date(byAdding: .day, value: days.count, to: first) else { return [:] }
        var dots: [Int: [String]] = [:]
        for child in FamilyStore.children {
            let tasks = (try? await APIClient.shared.fetchTasks(childId: child.id)) ?? []
            let events = (try? await APIClient.shared.fetchEvents(childId: child.id, from: first, to: end)) ?? []
            for day in days {
                guard let date = cal.date(byAdding: .day, value: day - 1, to: first) else { continue }
                if tasks.contains(where: { CalendarSync.applies($0, on: date) })
                    || events.contains(where: { CalendarSync.eventApplies($0, on: date) }) {
                    dots[day, default: []].append(child.id)
                }
            }
        }
        return dots
    }

    func loadCalendarMonth(year: Int, month: Int) async {
        CalendarData.dataYear = year
        CalendarData.dataMonth = month
        // What the phone already has for that month shows at once.
        TaskStore.shared.reload()
        TaskStore.shared.rebuildCalendar()
        // Tasks are already on the phone; only the month's events are new.
        await syncCalendar(children: FamilyStore.children, generation: Outbox.generation)
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

    /// Photo download links per occurrence, for the ones turned in
    /// (submitted or approved), all requested at once. Photos only: an old
    /// voice submission from before voice notes were removed is left out.
    private static func photoURLs(for occurrences: [ApiOccurrence]) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            for occ in occurrences where occ.status == "submitted" || occ.status == "approved" {
                group.addTask {
                    let subs = (try? await APIClient.shared.fetchSubmissions(occurrenceId: occ.id)) ?? []
                    return (occ.id, subs.filter { $0.kind == "photo" }.compactMap { $0.downloadUrl })
                }
            }
            var out: [String: [String]] = [:]
            for await (id, urls) in group { out[id] = urls }
            return out
        }
    }

    private func syncChild(_ apiChild: ApiChild, index: Int, existing: Child?) async throws -> Child {
        let id = apiChild.id
        // All at once rather than one after another: each is a round trip
        // to the server, and none depends on another.
        async let rulesFetch = APIClient.shared.fetchRules(childId: id)
        async let stateFetch = APIClient.shared.fetchState(childId: id)
        async let tasksFetch = APIClient.shared.fetchTasks(childId: id)
        async let occurrencesFetch = APIClient.shared.fetchOccurrences(childId: id)
        // Real available-today total (base limit, or a weekly_schedule
        // override for today, plus every grant/deduction). Best-effort: a
        // failure here shouldn't fail the whole sync.
        async let timeGrantsFetch = try? APIClient.shared.fetchTimeGrants(childId: id)
        // Also best-effort: app blocks are cached to stay correct offline,
        // and a failed fetch keeps the previous ones.
        async let appBlocksFetch = try? APIClient.shared.fetchAppBlocks(childId: id, activeOnly: false)
        // The server's combined answer (lock, blocks, allowance). A failed
        // fetch keeps the last one.
        async let policyFetch = try? APIClient.shared.fetchPolicy(childId: id)
        let rules = try await rulesFetch
        let state = try await stateFetch
        let apiTasks = try await tasksFetch
        let apiOccurrences = try await occurrencesFetch
        let timeGrants = await timeGrantsFetch
        let appBlocks = await appBlocksFetch
        let policy = await policyFetch

        // Photo links for everything turned in today, fetched together.
        let photosByOccurrence = await Self.photoURLs(for: apiOccurrences)
        try ensureCurrent(passGeneration)

        // Into the database in one batch; the screens follow from it
        // (TaskStore.reload), once.
        let store = LocalStore.shared
        store.batch {
            store.saveChild(apiChild, position: index, rules: rules, state: state, availableMinutes: timeGrants?.availableMinutes)
            store.saveTasks(apiTasks, childId: id)
            store.saveOccurrences(apiOccurrences, photos: photosByOccurrence, childId: id, dueDate: CalendarSync.isoDay(Date()))
            if let timeGrants { store.saveTimeGrants(timeGrants, childId: id) }
            if let appBlocks { store.saveAppBlocks(appBlocks, childId: id) }
            if let policy { store.savePolicy(policy) }
        }

        // The photos a parent is about to review start downloading now, so
        // they're ready when the card opens.
        if !isKidDevice {
            ImageCache.shared.prefetch(TaskStore.tasks(for: id).filter { $0.state == .review }.flatMap(\.photoURLs))
        }

        // Real total (base limit, or today's weekly_schedule override, plus
        // every grant/deduction) when that fetch succeeded, else the flat limit.
        let available = timeGrants?.availableMinutes ?? rules.dailyLimitMinutes
        return Self.makeChild(apiChild, rules: rules, state: state, availableMinutes: available, existing: existing)
    }

    // MARK: - Server rows -> what the screens show
    //
    // Shared by a sync and by launch (LocalStore.hydrate), so the phone's
    // saved copy opens looking exactly like a fresh sync.

    /// Today's list for one child: each task with today's occurrence.
    static func makeTasks(_ apiTasks: [ApiTask], occurrences: [ApiOccurrence], photos: [String: [String]]) -> [ChildTask] {
        let now = Date()
        return apiTasks.map { task in
            let occurrence = occurrences.first(where: { $0.taskId == task.id })

            let bypass = occurrence?.bypassRequested ?? false
            let uiState: TaskState
            switch occurrence?.status {
            case "approved": uiState = bypass ? .bypassed : .done
            case "submitted": uiState = .review
            case "rejected": uiState = .pending // a redo: goes back to the kid
            default: uiState = bypass ? .bypass : .pending
            }
            // A refused skip comes back as pending (the server withdraws
            // the ask) with the parent's note kept on it.
            var skipDeclinedNote: String? = nil
            if occurrence?.status == "pending", !bypass,
               let n = occurrence?.rejectionNote, !n.isEmpty {
                skipDeclinedNote = n
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
                dueDate = CalendarSync.nextOccurrence(of: task, after: now)
            } else if let time = CalendarSync.parseTime(task.dueTime) {
                dueDate = CalendarSync.date(on: now, minutes: time)
                dueLabel = CalendarSync.clock(minutes: time)
            }

            // What the kid actually turned in, photos only.
            let photoURLs = occurrence.flatMap { photos[$0.id] } ?? []

            return ChildTask(
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
                redoNote: redoNote,
                skipDeclinedNote: skipDeclinedNote,
                createdAt: CalendarSync.parseTimestamp(task.createdAt)
            )
        }
        .sortedForReview()
    }

    static func makeRules(_ rules: ApiChildRule) -> [ChildRule] {
        var childRules: [ChildRule] = [ChildRule(
            id: "screen-time-limit",
            kind: .screenTimeLimit,
            icon: "sf:hourglass",
            title: "Screen Time Limit",
            detail: "\(formatMinutes(rules.dailyLimitMinutes)) per day",
            on: true
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
        return childRules
    }

    /// The child, updated in place when already on screen (so views holding
    /// it keep it), else new.
    static func makeChild(_ apiChild: ApiChild, rules: ApiChildRule, state: ApiChildState,
                          availableMinutes: Int, existing: Child?) -> Child {
        let palette = FamilyStore.childColorPalette
        let color = palette[apiChild.colorIndex % palette.count]
        let childRules = makeRules(rules)
        let timeLeft = formatMinutes(availableMinutes)

        if let child = existing {
            // Only what changed: every assignment to a published property
            // redraws whatever shows the child, equal value or not, and a
            // sync that changed nothing must not redraw Home.
            func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Child, T>, _ value: T) {
                if child[keyPath: keyPath] != value { child[keyPath: keyPath] = value }
            }
            update(\.name, apiChild.name)
            update(\.color, color)
            update(\.rules, childRules)
            update(\.dailyLimitMin, rules.dailyLimitMinutes)
            update(\.manualLock, state.manualLock)
            update(\.taskGateOverride, state.taskGateOverride)
            update(\.timeLeft, timeLeft)
            update(\.timePct, availableMinutes > 0 ? 100 : 0)
            // Reflect real pairing state: the "1 device" row is only true
            // once a device has actually paired.
            if apiChild.isPaired && child.devices.isEmpty {
                child.devices = FamilyStore.demoDevice(apiChild.name)
            } else if !apiChild.isPaired && !child.devices.isEmpty {
                child.devices = []
            }
            return child
        }

        return Child(
            id: apiChild.id, name: apiChild.name, age: 10, dailyLimitMin: rules.dailyLimitMinutes,
            color: color, manualLock: state.manualLock, taskGateOverride: state.taskGateOverride,
            // No time left today reads as time's up (the header's hourglass).
            timeLeft: timeLeft, timePct: availableMinutes > 0 ? 100 : 0, usageTodayMin: 0,
            subtitle: "No tasks yet",
            devices: apiChild.isPaired ? FamilyStore.demoDevice(apiChild.name) : [],
            rules: childRules
        )
    }

    // MARK: - Calendar

    /// Fetches the displayed month's events, saves them on the phone, and
    /// builds the calendar.
    private func syncCalendar(children: [Child], generation: Int) async {
        let cal = Calendar(identifier: .gregorian)
        let monthStart = CalendarData.date(day: 1)
        let monthEnd = cal.date(byAdding: .day, value: CalendarData.daysInDataMonth, to: monthStart) ?? monthStart

        var fetched: [String: [ApiEvent]] = [:]
        for child in children {
            do {
                fetched[child.id] = try await APIClient.shared.fetchEvents(childId: child.id, from: monthStart, to: monthEnd)
            } catch {
                print("AppSync: events for \(child.id) failed: \(error.localizedDescription)")
                return // keep the previous calendar rather than showing a partial one
            }
        }
        guard Outbox.generation == generation else { rerunRequested = true; return }
        let store = LocalStore.shared
        store.batch {
            for child in children {
                store.saveEvents(fetched[child.id] ?? [], childId: child.id, from: monthStart, to: monthEnd)
            }
        }
    }

    /// The displayed month's calendar from server rows: events, and tasks
    /// with today's state.
    static func buildCalendar(events: [ApiEvent], tasks: [String: [ApiTask]], today: [String: [ChildTask]]) -> [Int: [CalEvent]] {
        var byDay: [Int: [CalEvent]] = [:]
        var seen = Set<String>()
        for e in events where seen.insert(e.id).inserted {
            if let (day, ev) = CalendarSync.calEvent(from: e) { byDay[day, default: []].append(ev) }
        }
        for (childId, childTasks) in tasks.sorted(by: { $0.key < $1.key }) {
            let todays = today[childId] ?? []
            for task in childTasks {
                let state = todays.first(where: { $0.id == task.id })?.state ?? .pending
                if let (day, ev) = CalendarSync.calEvent(from: task, childId: childId, todayState: state) {
                    byDay[day, default: []].append(ev)
                }
            }
        }
        return byDay
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
    static func isoString(_ date: Date) -> String { iso.string(from: date) }

    /// A server timestamp, which can carry microseconds ("…49.839097+00:00")
    /// that the ISO formatter doesn't read: the fraction is dropped.
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let known = timestampCache[s] { return known }
        let date = parseTimestampUncached(s)
        timestampCache[s] = date
        return date
    }

    // Each list rebuild asks again about every task; the answers for a given
    // timestamp, or a given task on a given day, don't change, so they're
    // worked out once. (Keyed by every field they depend on.)
    private static var timestampCache: [String: Date?] = [:]
    private static var nextOccurrenceCache: [String: Date] = [:]

    private static func parseTimestampUncached(_ s: String) -> Date? {
        if let date = parseISO(s) { return date }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return parseISO(trimmed) ?? parseISO(trimmed + "Z")
    }

    /// A calendar item the parent or kid just saved, in the server's shape,
    /// for the phone's database until the server's own row comes back.
    static func apiEvent(_ ev: CalEvent, id: String, start: Date, end: Date) -> ApiEvent {
        ApiEvent(
            id: id, childId: ev.personId, title: ev.title,
            startAt: isoString(start), endAt: isoString(end),
            locationOrLink: ev.location.isEmpty ? nil : ev.location, source: "manual",
            category: ev.category, note: ev.note,
            recurrence: ev.repeats == CalendarData.allDayCodes ? "daily" : ev.repeats,
            createdBy: ev.isKidPlan ? "child" : "parent", status: ev.planStatus.rawValue,
            reviewNote: ev.reviewNote
        )
    }

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

    /// The local calendar day a server timestamp falls on. Not
    /// parseDay(createdAt): that reads the first ten characters, which are
    /// the UTC date, so a task made after 5pm in California landed on
    /// tomorrow.
    static func localDay(ofTimestamp s: String?) -> Date? {
        parseTimestamp(s).map { cal.startOfDay(for: $0) }
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
        let key = "\(task.id)|\(task.recurrence)|\(task.dueDate ?? "")|\(task.createdAt ?? "")|\(isoDay(day))"
        if let known = appliesCache[key] { return known }
        let result = RepeatRule(task, fallbackStart: day).applies(on: day)
        appliesCache[key] = result
        return result
    }
    private static var appliesCache: [String: Bool] = [:]

    /// A task's repeat rule, read once: its start, and which days it falls
    /// on. Looking ahead for the next day a task applies asks up to a year
    /// of days, and re-reading the task for each one made rebuilding the
    /// lists slow enough to stall an animation on a phone.
    struct RepeatRule {
        private enum Days { case once, daily, weekly(String), codes(Set<String>) }
        private let startDay: Date
        private let boundary: Date
        private let days: Days

        init(_ task: ApiTask, fallbackStart: Date) {
            let start = CalendarSync.parseDay(task.dueDate) ?? CalendarSync.localDay(ofTimestamp: task.createdAt) ?? fallbackStart
            startDay = cal.startOfDay(for: start)
            // A UTC-anchored created_at fallback (no explicit due_date) can
            // already read as "tomorrow" on a device west of UTC the same
            // evening a task was created: a day of slack, as the server's
            // task_applies_on has. A due_date is an exact day: none.
            let slackDays = task.dueDate == nil ? 1 : 0
            boundary = cal.date(byAdding: .day, value: -slackDays, to: startDay) ?? startDay
            let rec = task.recurrence.trimmingCharacters(in: .whitespaces).lowercased()
            if rec.isEmpty || rec == "none" { days = .once }
            else if rec == "daily" { days = .daily }
            else if rec == "weekly" { days = .weekly(CalendarSync.weekdayCode(startDay)) }
            else { days = .codes(Set(rec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })) }
        }

        func applies(on day: Date) -> Bool {
            let d = cal.startOfDay(for: day)
            if case .once = days { return cal.isDate(d, inSameDayAs: startDay) }
            if d < boundary { return false }
            switch days {
            case .once: return false
            case .daily: return true
            case .weekly(let code): return CalendarSync.weekdayCode(d) == code
            case .codes(let codes): return codes.contains(CalendarSync.weekdayCode(d))
            }
        }

        /// The first day after `date` it applies, a year ahead at most.
        func next(after date: Date) -> Date? {
            if case .once = days { return startDay > date ? startDay : nil }
            for offset in 1...365 {
                if let d = cal.date(byAdding: .day, value: offset, to: date), applies(on: d) { return d }
            }
            return nil
        }
    }

    /// First day after `date` the task applies (looks a year ahead).
    /// Tomorrow's list for a child: each task that applies tomorrow, as not
    /// yet started, at its due time. Built from the task rules, not from
    /// occurrences: the server only creates a day's occurrence on that day.
    static func tomorrowTasks(from apiTasks: [ApiTask]) -> [ChildTask] {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return apiTasks.filter { applies($0, on: tomorrow) }.map { task in
            let time = parseTime(task.dueTime)
            return ChildTask(
                id: task.id, occurrenceId: nil, title: task.title, state: .pending,
                category: task.category ?? task.bucket, description: task.instructions ?? "",
                note: nil,
                dueLabel: time.map { clock(minutes: $0) },
                dueDate: time.map { date(on: tomorrow, minutes: $0) } ?? tomorrow,
                repeats: repeatCodes(task.recurrence),
                createdAt: parseTimestamp(task.createdAt)
            )
        }
        .sortedForTomorrow()
    }

    /// Whether an event falls on `day`: its own day, or for a repeat, a
    /// matching weekday on or after the day it starts.
    static func eventApplies(_ e: ApiEvent, on day: Date) -> Bool {
        guard e.childId != nil, let start = parseISO(e.startAt) else { return false }
        let d = cal.startOfDay(for: day), s = cal.startOfDay(for: start)
        let rec = e.recurrence.trimmingCharacters(in: .whitespaces).lowercased()
        if rec.isEmpty || rec == "none" { return cal.isDate(d, inSameDayAs: s) }
        if d < s { return false }
        if rec == "daily" { return true }
        if rec == "weekly" { return weekdayCode(d) == weekdayCode(s) }
        return rec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(weekdayCode(d))
    }

    static func nextOccurrence(of task: ApiTask, after date: Date) -> Date {
        let key = "\(task.id)|\(task.recurrence)|\(task.dueDate ?? "")|\(task.createdAt ?? "")|\(isoDay(date))"
        if let known = nextOccurrenceCache[key] { return known }
        let next = RepeatRule(task, fallbackStart: date).next(after: date) ?? cal.date(byAdding: .year, value: 1, to: date) ?? date
        nextOccurrenceCache[key] = next
        return next
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
        guard let childId = e.childId,
              let start = parseISO(e.startAt), let end = parseISO(e.endAt) else { return nil }
        let repeats = repeatCodes(e.recurrence)
        guard let day = placement(start: start, repeats: repeats) else { return nil }
        let category = e.category ?? "Activity"
        var ev = CalEvent(
            personId: childId,
            title: e.title, emoji: emojiForCalendarCategory(category),
            start: ChildRule.fmtClock(start), end: ChildRule.fmtClock(end),
            category: category, location: e.locationOrLink ?? "", note: e.note ?? "", repeats: repeats
        )
        ev.remoteId = e.id
        if let id = UUID(uuidString: e.id) { ev.id = id }
        ev.isKidPlan = e.createdBy == "child"
        ev.planStatus = PlanStatus(rawValue: e.status ?? "approved") ?? .approved
        ev.reviewNote = e.reviewNote
        return (day, ev)
    }

    static func calEvent(from t: ApiTask, childId: String, todayState: TaskState) -> (Int, CalEvent)? {
        let repeats = repeatCodes(t.recurrence)
        guard let startDay = parseDay(t.dueDate) ?? localDay(ofTimestamp: t.createdAt),
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
        if let id = UUID(uuidString: t.id) { ev.id = id }
        return (day, ev)
    }
}
