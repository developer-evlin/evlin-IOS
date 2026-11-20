import SwiftUI
import UIKit

enum ChildStatus: String {
    case unlocked, locked, lockedTasks = "locked-tasks", downtime
}

// Replaces the old static parent PIN: a kid requesting Parent Controls sets
// this to `.pending`, which only a parent tapping "Approve" inside that
// kid's own profile (ScreenProfile) can clear to `.approved` — there's no
// code the kid can type or guess on their own device. Consumed back to
// `.none` the moment it's used (by ScreenTabletHome, once it acts on
// `.approved`), so every entry attempt needs its own fresh approval —
// the MFA/passwordless equivalent of a PIN that only works once.
enum ParentApprovalStatus: Equatable {
    case none, pending, approved
}

/// Indigo/night accent for the downtime (schedule lock) state — kept
/// distinct from EColor.danger, which this design system reserves for
/// manual parent locks. A schedule lock is never red.
let downtimeIndigo = Color(hex: "5B5BD6")

struct RegisteredDevice: Identifiable {
    let id = UUID()
    var name: String
    var model: String
    var osVersion: String
    var pairedOn: String
    var lastActive: String
}

@MainActor
final class Child: Identifiable, ObservableObject {
    let id: String
    @Published var name: String
    @Published var age: Int
    @Published var dailyLimitMin: Int
    /// A limit per weekday ("mon"..."sun" -> minutes) when the days
    /// differ; empty when every day is dailyLimitMin. The server's
    /// weekly_schedule, which it and the kid's phone already apply.
    @Published var weeklySchedule: [String: Int] = [:]
    @Published var color: Color
    @Published var manualLock: Bool
    @Published var taskGateOverride: Bool
    /// Work sent in opens the phone, without waiting for approval.
    @Published var instantUnlock = false
    @Published var timeLeft: String
    @Published var timePct: Int
    @Published var usageTodayMin: Int

    // Today's tasks only. TaskStore's list also holds the child's tasks
    // for other days (as "pending", parked on their next day), and counting
    // those kept the phone locked after every one of today's was approved.
    private var todaysTasks: [ChildTask] { TaskStore.tasks(for: id).filter(\.isDueToday) }
    var tasksTotal: Int { todaysTasks.count }
    var tasksDone: Int { todaysTasks.filter { $0.state == .done }.count }
    
    var status: ChildStatus {
        if manualLock { return .locked }
        if downtimeUntil != nil { return .downtime }
        
        if !taskGateOverride {
            let pending = todaysTasks.filter { $0.state == .pending || ($0.state == .review && !instantUnlock) }
            if !pending.isEmpty { return .lockedTasks }
        }
        
        return .unlocked
    }
    @Published var subtitle: String
    /// Set only when status == .downtime — the schedule's end time, e.g.
    /// "7:00 AM". timeLeft/timePct still track the *unused daily allowance*
    /// while downtime is active; they're unrelated to when downtime ends.
    @Published var downtimeUntil: String?
    @Published var parentApprovalStatus: ParentApprovalStatus = .none
    @Published var devices: [RegisteredDevice]
    // Demo-only flag for previewing the paywall nudge that would show on a
    // profile once the free trial runs out — no real trial/entitlement
    // tracking exists in this prototype, so this is set by hand on one mock
    // child rather than computed.
    @Published var trialExhausted: Bool
    // Demo-only flag for previewing the "lock this down" nudge that would
    // show on a profile where the parent never finished the tamper-proofing
    // step from onboarding (ParentSetPasscodeV2Step) — no real device-level
    // Screen Time/Family Sharing detection exists in this prototype, so
    // this is set by hand on one mock child rather than computed.
    @Published var needsProtectionSetup: Bool
    // Owned by the Child itself (not re-seeded per ScreenProfile instance
    // any more) so a rule survives navigating away and back, and so
    // anything else holding this same Child — chat's block-an-app flow,
    // eventually — can add/update a rule that actually shows up on the
    // profile instead of only existing in that one screen's local state.
    @Published var rules: [ChildRule]

    init(id: String, name: String, age: Int, dailyLimitMin: Int, color: Color, manualLock: Bool = false, taskGateOverride: Bool = false, timeLeft: String, timePct: Int, usageTodayMin: Int, subtitle: String, downtimeUntil: String? = nil, parentApprovalStatus: ParentApprovalStatus = .none, devices: [RegisteredDevice] = [], trialExhausted: Bool = false, needsProtectionSetup: Bool = false, rules: [ChildRule] = []) {
        self.id = id; self.name = name; self.age = age; self.dailyLimitMin = dailyLimitMin
        self.color = color; self.manualLock = manualLock; self.taskGateOverride = taskGateOverride; self.timeLeft = timeLeft; self.timePct = timePct
        self.usageTodayMin = usageTodayMin;
        self.subtitle = subtitle; self.downtimeUntil = downtimeUntil
        self.parentApprovalStatus = parentApprovalStatus
        self.trialExhausted = trialExhausted
        self.needsProtectionSetup = needsProtectionSetup
        self.rules = rules.isEmpty ? TaskStore.rules(dailyLimitMin: dailyLimitMin) : rules
        // No auto-synthesized device: an empty array is the honest "not
        // paired yet" state Settings' Family list and Child sheet need to
        // be able to show (see ScreenSettings' AddChildSheet, which creates
        // a profile with no device on purpose — pairing is a separate,
        // later step). Every seeded demo child below passes its own
        // `devices:` explicitly to read as already paired.
        self.devices = devices
    }
}

@MainActor
enum FamilyStore {
    // Same shape the old init()-level fallback used to synthesize —
    // kept around for addOnboardedChild below (used to read `private`
    // when every demo child below passed it explicitly; now the real
    // onboarding-created child is the only caller).
    static func demoDevice(_ childName: String) -> [RegisteredDevice] {
        [RegisteredDevice(name: "\(childName)'s iPhone", model: "iPhone 14", osVersion: "iOS 17.4.1", pairedOn: "Sep 12, 2025", lastActive: "Active now")]
    }

    // Starts empty — real children only ever come from onboarding
    // (RootView's onComplete calling addOnboardedChild below) or from
    // Settings' "Add a child" flow. Used to be 12 hardcoded demo kids, one
    // per status, kept around purely to preview how each status card
    // looked — that reference state is preserved in git history (see the
    // "Checkpoint" commit) now that the app always starts a real family
    // from onboarding instead.
    static var children: [Child] = []

    static func clear() {
        children = []
    }


    // What onboarding calls once pairing finishes — mirrors Settings' own
    // "Add a child" defaults (dailyLimitMin: 60, status: .unlocked, no
    // tasks yet) since that's the existing precedent for "what a brand-new
    // child should look like." Locking the phone and any status change
    // beyond this happens later, as a real consequence of the parent
    // assigning that child's first task — see ScreenProfile's AddTaskSheet.
    @discardableResult
    static func addOnboardedChild(name: String) -> Child {
        let child = Child(
            id: SessionManager.shared.activeChildId ?? "unknown", name: name, age: 10, dailyLimitMin: 60,
            color: childColorPalette[0], manualLock: false, taskGateOverride: false,
            timeLeft: formatMinutes(60), timePct: 100, usageTodayMin: 0,
            subtitle: "No tasks yet",
            devices: demoDevice(name)
        )
        children.append(child)
        return child
    }

    static func child(_ id: String) -> Child {
        children.first { $0.id == id } ?? children.first ?? Child(
            id: "none", name: "—", age: 0, dailyLimitMin: 60, color: .gray,
            manualLock: false, timeLeft: "0m", timePct: 0, usageTodayMin: 0, subtitle: ""
        )
    }

    static func removeChild(_ id: String) {
        children.removeAll { $0.id == id }
    }

    static func removeDevice(_ deviceId: UUID, from childId: String) {
        child(childId).devices.removeAll { $0.id == deviceId }
    }

    // Indexed by the child's color_index (the backend gives the first child
    // 0, the next 1, …), so the first entry is every family's first child:
    // Evlin green.
    static let childColorPalette: [Color] = [
        Color(hex: "3DAA5C"), Color(hex: "2563EB"), Color(hex: "F97316"), Color(hex: "7C3AED"),
        Color(hex: "0EA5E9"), Color(hex: "EC4899"), Color(hex: "0891B2"), Color(hex: "6366F1"),
    ]

    static func nextChildColor() -> Color {
        childColorPalette[children.count % childColorPalette.count]
    }
}

func formatMinutes(_ min: Int) -> String {
    if min <= 0 { return "0m" }
    let h = min / 60, m = min % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

/// A child's screen-time limit as the parent sets it: every day the same,
/// or customised day by day. Stored as the server stores it: dailyLimitMin
/// plus weekly_schedule (empty for every day, all seven days otherwise).
/// Downtime's chosen days use the same weekday codes.
enum ScreenTimeSchedule {
    enum Mode: Hashable { case everyDay, customDays }

    /// Monday first, as the server counts.
    static let days = EnforcementCalculator.weekdayCodes
    static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    static let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let shortNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Each day's limit, Monday first.
    static func minutes(daily: Int, weekly: [String: Int]) -> [Int] {
        days.map { weekly[$0] ?? daily }
    }

    static func mode(daily: Int, weekly: [String: Int]) -> Mode {
        Set(minutes(daily: daily, weekly: weekly)).count == 1 ? .everyDay : .customDays
    }

    /// Today's place in the week, Monday = 0.
    static var todayIndex: Int {
        days.firstIndex(of: EnforcementCalculator.weekdayCode(for: Date())) ?? 0
    }

    /// "1h 30m a day", or "Custom days".
    static func summary(daily: Int, weekly: [String: Int]) -> String {
        let m = minutes(daily: daily, weekly: weekly)
        return mode(daily: daily, weekly: weekly) == .everyDay ? "\(limitText(m[0])) a day" : "Custom days"
    }

    /// Chosen weekdays in words: "Every day", "Weekdays", "Weekends", or
    /// "Mon, Wed, Fri". Empty or all seven is every day.
    static func daysText(_ chosen: Set<String>) -> String {
        if chosen.isEmpty || chosen.count == 7 { return "Every day" }
        if chosen == Set(days.prefix(5)) { return "Weekdays" }
        if chosen == Set(days.suffix(2)) { return "Weekends" }
        return days.indices.filter { chosen.contains(days[$0]) }.map { shortNames[$0] }.joined(separator: ", ")
    }

    /// A day's limit in words: none is "None".
    static func limitText(_ minutes: Int) -> String {
        minutes <= 0 ? "None" : formatMinutes(minutes)
    }
}
