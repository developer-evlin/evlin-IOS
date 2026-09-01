import SwiftUI

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

struct ChildReflection {
    var minutes: Int
    var writtenText: String
    var review: String // "pending" | "approved" | "redo"
}

final class Child: Identifiable, ObservableObject {
    let id: String
    @Published var name: String
    @Published var age: Int
    @Published var dailyLimitMin: Int
    @Published var color: Color
    @Published var status: ChildStatus
    @Published var timeLeft: String
    @Published var timePct: Int
    @Published var usageTodayMin: Int
    @Published var tasksDone: Int
    @Published var tasksTotal: Int
    @Published var subtitle: String
    @Published var reflection: ChildReflection?
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

    init(id: String, name: String, age: Int, dailyLimitMin: Int, color: Color, status: ChildStatus, timeLeft: String, timePct: Int, usageTodayMin: Int, tasksDone: Int = 0, tasksTotal: Int = 5, subtitle: String, reflection: ChildReflection? = nil, downtimeUntil: String? = nil, parentApprovalStatus: ParentApprovalStatus = .none, devices: [RegisteredDevice] = [], trialExhausted: Bool = false) {
        self.id = id; self.name = name; self.age = age; self.dailyLimitMin = dailyLimitMin
        self.color = color; self.status = status; self.timeLeft = timeLeft; self.timePct = timePct
        self.usageTodayMin = usageTodayMin; self.tasksDone = tasksDone; self.tasksTotal = tasksTotal
        self.subtitle = subtitle; self.reflection = reflection; self.downtimeUntil = downtimeUntil
        self.parentApprovalStatus = parentApprovalStatus
        self.trialExhausted = trialExhausted
        // Every kid has at least one paired device in real usage — synthesize
        // a plausible default (their own device, on the app's current min
        // supported iOS) rather than leaving this empty when a specific
        // model isn't worth hand-authoring per child.
        self.devices = devices.isEmpty
            ? [RegisteredDevice(name: "\(name)'s iPhone", model: "iPhone 14", osVersion: "iOS 17.4.1", pairedOn: "Sep 12, 2025", lastActive: "Active now")]
            : devices
    }
}

enum FamilyStore {
    static var children: [Child] = [
        Child(id: "liam", name: "Liam", age: 12, dailyLimitMin: 120, color: Color(hex: "2563EB"), status: .unlocked, timeLeft: "1h 30m", timePct: 75, usageTodayMin: 96, subtitle: "Focused today · 3 of 5 tasks done"),
        Child(id: "maya", name: "Maya", age: 8, dailyLimitMin: 60, color: Color(hex: "3DAA5C"), status: .unlocked, timeLeft: "45m", timePct: 38, usageTodayMin: 22, subtitle: "On bedtime wind-down in 2h"),
        Child(id: "emma", name: "Emma", age: 6, dailyLimitMin: 30, color: Color(hex: "F97316"), status: .locked, timeLeft: "0m", timePct: 0, usageTodayMin: 30, subtitle: "Quiet time · unlocks at 4:00 PM"),
        Child(id: "noah", name: "Noah", age: 9, dailyLimitMin: 45, color: Color(hex: "7C3AED"), status: .lockedTasks, timeLeft: "0m", timePct: 0, usageTodayMin: 0, tasksDone: 1, tasksTotal: 5, subtitle: "Locked · finish today's tasks to earn screen time"),
        Child(id: "sam", name: "Sam", age: 11, dailyLimitMin: 90, color: Color(hex: "0EA5E9"), status: .locked, timeLeft: "0m", timePct: 0, usageTodayMin: 41, subtitle: "Reflection time in progress",
              reflection: ChildReflection(minutes: 15, writtenText: "I felt frustrated when my time ran out — I was almost done with my level. Tomorrow I'll set a timer 10 minutes early so I can save first.", review: "pending")),
        Child(id: "ava", name: "Ava", age: 10, dailyLimitMin: 100, color: downtimeIndigo, status: .downtime, timeLeft: "1h 20m", timePct: 80, usageTodayMin: 0, subtitle: "Downtime · until 7:00 AM",
              downtimeUntil: "7:00 AM"),
        // All tasks done, but the daily allowance ran out — distinct from
        // Noah (locked, tasks still open) and Emma (locked, schedule-based).
        // Unlocking here should be a deliberate "how much extra time" grant,
        // not a plain confirm — see ScreenProfile's grantTimeSheet.
        Child(id: "zoe", name: "Zoe", age: 9, dailyLimitMin: 75, color: Color(hex: "EC4899"), status: .locked, timeLeft: "0m", timePct: 0, usageTodayMin: 75, tasksDone: 5, tasksTotal: 5, subtitle: "All tasks done · screen time used up for today"),
        // Seeded already .pending so opening this profile shows
        // approvalBanner (ScreenProfile) immediately — a way to see the
        // parent-approval popup without first switching to Kid mode and
        // tapping "Parent controls" there to generate a real request.
        Child(id: "jake", name: "Jake", age: 13, dailyLimitMin: 90, color: Color(hex: "0891B2"), status: .unlocked, timeLeft: "1h 10m", timePct: 60, usageTodayMin: 36, subtitle: "Requested Parent Controls access", parentApprovalStatus: .pending),
        // Empty profile — no tasks assigned yet, for seeing what a brand-new
        // kid's profile looks like before a parent adds anything.
        Child(id: "alex", name: "Alex", age: 7, dailyLimitMin: 60, color: Color(hex: "6366F1"), status: .unlocked, timeLeft: "1h 0m", timePct: 100, usageTodayMin: 0, tasksDone: 0, tasksTotal: 0, subtitle: "No tasks yet"),
        // Empty profile — for previewing the "free trial exhausted" upgrade
        // nudge in place of the normal tasks section.
        Child(id: "mia", name: "Mia", age: 6, dailyLimitMin: 45, color: Color(hex: "14B8A6"), status: .unlocked, timeLeft: "45m", timePct: 100, usageTodayMin: 0, tasksDone: 0, tasksTotal: 0, subtitle: "Free trial ended", trialExhausted: true),
    ]

    static func child(_ id: String) -> Child { children.first { $0.id == id } ?? children[0] }

    static func removeChild(_ id: String) {
        children.removeAll { $0.id == id }
    }

    static func removeDevice(_ deviceId: UUID, from childId: String) {
        child(childId).devices.removeAll { $0.id == deviceId }
    }

    private static let childColorPalette: [Color] = [
        Color(hex: "2563EB"), Color(hex: "3DAA5C"), Color(hex: "F97316"), Color(hex: "7C3AED"),
        Color(hex: "0EA5E9"), Color(hex: "EC4899"), Color(hex: "0891B2"), Color(hex: "6366F1"),
    ]

    static func nextChildColor() -> Color {
        childColorPalette[children.count % childColorPalette.count]
    }
}

// Mock 7-day family total (Mon–Sun) used to draw the analytics trend chart.
enum WeekUsage {
    static let days: [(d: String, min: Int)] = [
        ("M", 224), ("T", 268), ("W", 191), ("T", 302), ("F", 246), ("S", 355), ("S", 168),
    ]
}

func formatMinutes(_ min: Int) -> String {
    if min <= 0 { return "0m" }
    let h = min / 60, m = min % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}
