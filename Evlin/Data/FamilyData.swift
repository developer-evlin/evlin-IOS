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

struct ChildReflection {
    var minutes: Int
    var writtenText: String
    var review: String // "pending" | "approved" | "redo"
}

@MainActor
final class Child: Identifiable, ObservableObject {
    let id: String
    @Published var name: String
    @Published var age: Int
    @Published var dailyLimitMin: Int
    @Published var color: Color
    @Published var manualLock: Bool
    @Published var taskGateOverride: Bool
    @Published var timeLeft: String
    @Published var timePct: Int
    @Published var usageTodayMin: Int

    var tasksTotal: Int { TaskStore.tasks(for: id).count }
    var tasksDone: Int { TaskStore.tasks(for: id).filter { $0.state == .done }.count }
    
    var status: ChildStatus {
        if manualLock { return .locked }
        if downtimeUntil != nil { return .downtime }
        
        if !taskGateOverride {
            let pending = TaskStore.tasks(for: id).filter { $0.state == .pending || $0.state == .review }
            if !pending.isEmpty { return .lockedTasks }
        }
        
        return .unlocked
    }
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
    // Demo-only flag for previewing the "lock this down" nudge that would
    // show on a profile where the parent never finished the tamper-proofing
    // step from onboarding (ParentSetPasscodeV2Step) — no real device-level
    // Screen Time/Family Sharing detection exists in this prototype, so
    // this is set by hand on one mock child rather than computed.
    @Published var needsProtectionSetup: Bool
    // Editable from Settings > Children & Devices (EditChildProfileSheet) —
    // nil falls back to a colored initials circle wherever a child's
    // avatar is shown.
    @Published var avatar: UIImage?
    // Owned by the Child itself (not re-seeded per ScreenProfile instance
    // any more) so a rule survives navigating away and back, and so
    // anything else holding this same Child — chat's block-an-app flow,
    // eventually — can add/update a rule that actually shows up on the
    // profile instead of only existing in that one screen's local state.
    @Published var rules: [ChildRule]

    init(id: String, name: String, age: Int, dailyLimitMin: Int, color: Color, manualLock: Bool = false, taskGateOverride: Bool = false, timeLeft: String, timePct: Int, usageTodayMin: Int, subtitle: String, reflection: ChildReflection? = nil, downtimeUntil: String? = nil, parentApprovalStatus: ParentApprovalStatus = .none, devices: [RegisteredDevice] = [], trialExhausted: Bool = false, needsProtectionSetup: Bool = false, avatar: UIImage? = nil, rules: [ChildRule] = []) {
        self.id = id; self.name = name; self.age = age; self.dailyLimitMin = dailyLimitMin
        self.color = color; self.manualLock = manualLock; self.taskGateOverride = taskGateOverride; self.timeLeft = timeLeft; self.timePct = timePct
        self.usageTodayMin = usageTodayMin;
        self.subtitle = subtitle; self.reflection = reflection; self.downtimeUntil = downtimeUntil
        self.parentApprovalStatus = parentApprovalStatus
        self.trialExhausted = trialExhausted
        self.needsProtectionSetup = needsProtectionSetup
        self.avatar = avatar
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

    // Not private any more — Settings' Child sheet needs the same palette
    // for its colour-swatch row (current colour ringed, tap to change).
    static let childColorPalette: [Color] = [
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

/// Downsample an image to a maximum pixel dimension, preventing multi-MB
/// photos from living in memory at full resolution just to display a
/// 104-pt avatar circle.
func downsampledAvatar(_ image: UIImage, maxPixels: CGFloat = 312) -> UIImage {
    let size = image.size
    let longer = max(size.width, size.height)
    guard longer > maxPixels else { return image }
    let scale = maxPixels / longer
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
}
