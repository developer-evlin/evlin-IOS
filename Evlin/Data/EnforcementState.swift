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
    /// at once, and each has to clear on its own: finishing a reflection
    /// doesn't satisfy outstanding tasks, and vice versa.
    var lockReasons: [LockReason]

    /// Minutes available today: the day's base allowance plus every
    /// grant/deduction credited to today, floored at zero.
    var minutesToday: Int

    /// Apps blocked by an unresolved block. These are shielded individually
    /// rather than by the whole-device lock, so they stay blocked even when
    /// `isLocked` is false — "no YouTube until homework is done" is not the
    /// same statement as "the phone is locked".
    var blockedAppBundleIDs: [String]

    enum LockReason: String, Equatable {
        /// Priority 0: an assigned reflection hasn't been finished and
        /// approved. Holds regardless of task status.
        case openReflection
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

extension LocalStore {
    /// Reads the cache and answers both questions at once.
    ///
    /// `dueDate`/`creditedDate` are the child's own local day, not the
    /// server's — the same string format the rest of the cache is keyed by.
    func enforcementState(childId: String, day: Date = Date()) -> EnforcementState {
        let dayKey = CalendarSync.isoDay(day)
        let state = cachedChildState(childId: childId)

        var reasons: [EnforcementState.LockReason] = []

        if cachedReflections(childId: childId).contains(where: { $0.isOpen }) {
            reasons.append(.openReflection)
        }

        // Only tasks that gate apps count — a task marked "doesn't gate" is
        // deliberately not a reason to lock anything.
        let occurrences = cachedOccurrences(childId: childId, dueDate: dayKey)
        let tasksByID = Dictionary(uniqueKeysWithValues: cachedTasks(childId: childId).map { ($0.id, $0) })
        let gatingUnfinished = occurrences.contains { occ in
            guard occ.status != "approved" else { return false }
            return tasksByID[occ.taskId]?.gatesApps ?? true
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

        let blocked = cachedAppBlocks(childId: childId)
            .filter { !$0.resolved }
            .compactMap { $0.appBundleId }

        return EnforcementState(lockReasons: reasons, minutesToday: minutes, blockedAppBundleIDs: blocked)
    }
}
