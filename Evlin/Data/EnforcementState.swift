import Foundation

/// The one answer to "should this device be locked right now, and how many
/// minutes does it have today" — computed from locally cached rows only.
///
/// This lives outside any View on purpose. Today it backs the in-app lock;
/// when real enforcement lands, `ManagedSettingsStore` and a
/// `DeviceActivityMonitor` extension consume this same value from the same
/// shared store, in a different process. A View's computed property couldn't
/// be read from either, and two implementations of "is it locked" that
/// disagree is the worst possible outcome for a lock.
///
/// Everything here reads cached data, so it is correct with no connectivity —
/// including the case that matters most: a kid finishing their last task
/// clears the lock immediately, with no round trip.
struct EnforcementState: Equatable {
    /// Locked for any reason. Independent gates, OR'd — see `lockReasons`.
    var isLocked: Bool { !lockReasons.isEmpty }

    /// Every reason the device is currently locked. More than one can apply
    /// at once, and each has to clear on its own: a parent lifting a manual
    /// lock doesn't satisfy outstanding tasks, and vice versa.
    var lockReasons: [LockReason]

    /// Minutes available today: the day's base allowance plus every
    /// grant/deduction credited to today, floored at zero. nil when the
    /// parent has switched the daily limit off — no limit, not zero.
    var minutesToday: Int?

    /// Catalog app ids blocked right now. These are blocked individually
    /// rather than by the whole-device lock, so they stay blocked even when
    /// `isLocked` is false — "no YouTube until homework is done" is not the
    /// same statement as "the phone is locked".
    var blockedAppIDs: [String]

    enum LockReason: String, Equatable {
        /// At least one task that gates apps isn't approved yet.
        case unfinishedTasks
        /// A parent locked it by hand.
        case manualLock
    }
}

enum EnforcementCalculator {
    /// Monday-first, matching the backend's `_WEEKDAY_CODES` and
    /// `date.weekday()`. Foundation's `Calendar` is Sunday-first, hence the
    /// remap rather than indexing it directly.
    static let weekdayCodes = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    static func weekdayCode(for date: Date, calendar: Calendar = .current) -> String {
        let sundayFirst = calendar.component(.weekday, from: date)  // 1 = Sunday
        let mondayFirst = (sundayFirst + 5) % 7                     // 0 = Monday
        return weekdayCodes[mondayFirst]
    }

    /// Mirrors the backend's `_base_limit_for`: a weekly_schedule entry for
    /// this weekday wins, otherwise the flat daily limit.
    ///
    /// This is a deliberate second implementation of a server rule, which is
    /// the only way the budget can be known offline — but the app has been
    /// bitten before by such a mirror drifting from the backend
    /// (CalendarSync vs. task_applies_on), so the cases here are pinned by
    /// tests written against the backend's own behaviour.
    /// `calendar` defaults to the device's own, which is what production
    /// wants — the child's local Saturday should get Saturday's allowance,
    /// not UTC's. It's a parameter rather than a hardcoded `.current` so
    /// that's an explicit, checkable choice: hardcoding it made the weekday
    /// impossible to pin down from outside, which is precisely how a mirror
    /// like this drifts from the backend without anyone noticing.
    static func baseLimit(dailyLimitMinutes: Int, weeklySchedule: [String: Int]?, on date: Date,
                          calendar: Calendar = .current) -> Int {
        if let schedule = weeklySchedule, !schedule.isEmpty,
           let override = schedule[weekdayCode(for: date, calendar: calendar)] {
            return override
        }
        return dailyLimitMinutes
    }

    /// Mirrors `get_time_grants`: base allowance + the day's signed grants,
    /// floored at zero (a deduction can't make the pool negative).
    static func minutesAvailable(dailyLimitMinutes: Int, weeklySchedule: [String: Int]?,
                                 grantedMinutes: Int, on date: Date,
                                 calendar: Calendar = .current) -> Int {
        max(0, baseLimit(dailyLimitMinutes: dailyLimitMinutes, weeklySchedule: weeklySchedule,
                         on: date, calendar: calendar)
               + grantedMinutes)
    }
}

/// One app blocked right now, with the server's own wording for why.
struct BlockedApp: Equatable, Identifiable {
    let id: String          // the block's id
    let appId: String?
    let name: String
    let detail: String      // "until 'Homework' is approved"
}

extension EnforcementState.LockReason {
    /// The policy's names for the same reasons.
    init?(policyName: String) {
        switch policyName {
        case "unfinished_tasks": self = .unfinishedTasks
        case "manual_lock": self = .manualLock
        default: return nil
        }
    }
}

extension LocalStore {
    /// Reads the cache and answers both questions at once.
    ///
    /// Today's policy from the server is the answer when it's cached — the
    /// same computation the parent's side sees, rather than a second copy
    /// of the rules. With none for today (a new day while offline), it's
    /// worked out here from the cached rows, as before.
    ///
    /// `dueDate`/`creditedDate` are the child's own local day, not the
    /// server's — the same string format the rest of the cache is keyed by.
    func enforcementState(childId: String, day: Date = Date()) -> EnforcementState {
        let dayKey = CalendarSync.isoDay(day)
        let blocked = Array(Set(blockedNow(childId: childId, at: day).compactMap(\.appId)))

        if let policy = cachedPolicy(childId: childId), policy.localDate == dayKey {
            return EnforcementState(
                lockReasons: policy.lockReasons.compactMap(EnforcementState.LockReason.init(policyName:)),
                minutesToday: policy.allowanceMinutes,
                blockedAppIDs: blocked
            )
        }

        let state = cachedChildState(childId: childId)

        var reasons: [EnforcementState.LockReason] = []

        // Today's tasks come from the saved task rules (repeat days, start
        // date), the way the server decides them (CalendarSync.applies), not
        // only from today's saved occurrences: on a new day with no
        // connection and the app not opened, there are none yet, and the
        // phone would have unlocked. An occurrence, where there is one, says
        // how far the task has got. Only tasks that gate apps count. Reads
        // only, so a separate process (a Screen Time extension) can use it.
        let occurrences = cachedOccurrences(childId: childId, dueDate: dayKey)
        let occurrenceByTask = Dictionary(occurrences.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
        let gatingUnfinished = cachedTasks(childId: childId).contains { task in
            guard task.gatesApps else { return false }
            let occurrence = occurrenceByTask[task.id]
            guard occurrence != nil || CalendarSync.applies(task, on: day) else { return false }
            return occurrence?.status != "approved"
        }
        if gatingUnfinished && !(state?.taskGateOverride ?? false) {
            reasons.append(.unfinishedTasks)
        }

        if state?.manualLock == true {
            reasons.append(.manualLock)
        }

        let granted = cachedTimeGrants(childId: childId, creditedDate: dayKey)
            .reduce(0) { $0 + $1.minutes }
        let minutes = EnforcementCalculator.minutesAvailable(
            dailyLimitMinutes: state?.dailyLimitMinutes ?? 60,
            weeklySchedule: state?.weeklySchedule,
            grantedMinutes: granted,
            on: day
        )

        return EnforcementState(lockReasons: reasons, minutesToday: minutes, blockedAppIDs: blocked)
    }

    /// What's blocked at `now`, from the cached policy where there is one.
    ///
    /// Time moves between syncs, so this doesn't just replay the server's
    /// list: a block past its end drops off, and scheduled windows are
    /// evaluated here, in the child's zone, so "no games after 7" starts at
    /// 7 whether or not the device synced at 7.
    func blockedNow(childId: String, at now: Date = Date()) -> [BlockedApp] {
        guard let policy = cachedPolicy(childId: childId) else {
            return cachedAppBlocks(childId: childId).filter { $0.isActive(at: now) }.map {
                BlockedApp(id: $0.id, appId: $0.appId, name: $0.appName, detail: $0.summary ?? "")
            }
        }
        let zone = TimeZone(identifier: policy.timezone) ?? .current
        var result: [BlockedApp] = policy.blockedNow.filter { $0.kind != "scheduled" }.compactMap { b in
            if let until = b.until.flatMap(CalendarSync.parseISO), until <= now { return nil }
            return BlockedApp(id: b.blockId, appId: b.appId, name: b.appName, detail: b.description)
        }
        for s in policy.scheduledBlocks {
            guard let end = Self.windowEnd(days: s.days, start: s.start, end: s.end, at: now, zone: zone) else { continue }
            let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "HH:mm"
            result.append(BlockedApp(id: s.blockId, appId: s.appId, name: s.appName, detail: "until \(f.string(from: end))"))
        }
        return result
    }

    /// If `now` is inside the weekly window, when that window ends. A
    /// window belongs to the day it starts on, so an overnight one is still
    /// running after midnight — the same rule as the server's blocks.py.
    static func windowEnd(days: String, start: String, end: String, at now: Date, zone: TimeZone) -> Date? {
        guard let s = BlockDraft.clock(start), let e = BlockDraft.clock(end), s != e else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let codes = Set(days.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        let mondayFirst = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        func code(_ d: Date) -> String { mondayFirst[(cal.component(.weekday, from: d) + 5) % 7] }
        func at(_ day: Date, _ minutes: Int) -> Date {
            cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
        }
        let today = cal.startOfDay(for: now)
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: today), codes.contains(code(day)) else { continue }
            let startAt = at(day, s)
            let endAt = e > s ? at(day, e) : at(cal.date(byAdding: .day, value: 1, to: day) ?? day, e)
            if startAt <= now && now < endAt { return endAt }
        }
        return nil
    }
}
