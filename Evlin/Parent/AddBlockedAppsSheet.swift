import SwiftUI

/// Blocking an app from a child's screen time page: one app, and for how
/// long. Both have to be picked before Block does anything. Settings-style choices only (a set time, a custom length, the
/// rest of the day, or no end time, until lifted); blocks tied to a task or a weekly
/// schedule stay in Chat's "Block an app" card. Saved through the outbox and
/// shown on the page straight away.
/// How long a block lasts: the same five choices wherever a parent blocks an
/// app, by hand here or from a chat card (AppBlockCards.swift).
enum BlockLength: String, Hashable, CaseIterable {
    case thirtyMinutes = "30_minutes", oneHour = "1_hour", custom, restOfToday = "rest_of_today", always = "no_end_time"

    var title: String {
        switch self {
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .custom: return "Custom"
        case .restOfToday: return "Rest of today"
        // Until the parent lifts it from the app's page. "No end time" was
        // judged not professional (2026-11-05).
        case .always: return "Always"
        }
    }

    /// Minutes from now, or nil for until the parent allows it. "Rest of
    /// today" ends at midnight where the child is, not where the parent is,
    /// and is worked out at the tap, not when the card was drafted.
    @MainActor func minutes(childId: String, custom: Int) -> Int? {
        switch self {
        case .thirtyMinutes: return 30
        case .oneHour: return 60
        case .custom: return max(5, custom)
        case .always: return nil
        case .restOfToday:
            var calendar = Calendar(identifier: .gregorian)
            if let tz = LocalStore.shared.cachedPolicy(childId: childId).flatMap({ TimeZone(identifier: $0.timezone) }) {
                calendar.timeZone = tz
            }
            let now = Date()
            let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            return max(1, Int(midnight.timeIntervalSince(now) / 60))
        }
    }
}

enum AppBlocking {
    /// Blocks apps for a child: on the phone straight away, and to the server
    /// through the outbox. The one save for the sheet and the chat card.
    @MainActor
    static func block(childId: String, apps: [(id: String, name: String)], minutes: Int?) {
        guard !apps.isEmpty else { return }
        LocalStore.shared.mirrorBlocksCreated(childId: childId, apps: apps,
                                              endsAt: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
        Outbox.send(APIClient.Write.createAppBlocks(childId: childId, appIds: apps.map(\.id), durationMinutes: minutes),
                    childId: childId, label: "Blocking \(AppBlockDraftCard.list(apps.map(\.name)))")
        SyncState.shared.version += 1
    }
}

/// The five lengths as a settings-style list, with hour and minute wheels
/// under Custom. Shared by the sheet and the chat card so they're identical.
struct BlockLengthPicker: View {
    @Binding var length: BlockLength?
    @Binding var customHours: Int
    @Binding var customMinutes: Int
    var accent: Color = FormGreen.accent
    /// In a form (the sheet), scrolls it down; elsewhere (the chat card) nothing.
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(BlockLength.allCases.enumerated()), id: \.element) { i, option in
                if i > 0 { Divider().padding(.leading, 16) }
                row(option)
                if option == .custom && length == .custom {
                    wheels.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Custom opens its wheels and the form scrolls down to show them
        // whole, so the length can be set without hunting for it.
        .onChange(of: length) { _, new in
            guard new == .custom else { return }
            // After the wheels have opened, so the scroll reaches their end.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrollFormToBottom() }
        }
    }

    /// Hours and minutes, the way iOS's own timers pick a length.
    private var wheels: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: $customHours) {
                ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
            }
            Picker("Minutes", selection: $customMinutes) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 150)
        .padding(.horizontal, 8)
        .onChange(of: customHours) { _, h in if h == 0 && customMinutes == 0 { customMinutes = 5 } }
        .onChange(of: customMinutes) { _, m in if customHours == 0 && m == 0 { customMinutes = 5 } }
    }

    private var customText: String {
        switch (customHours, customMinutes) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) h"
        case (let h, let m): return "\(h) h \(m) min"
        }
    }

    private func row(_ option: BlockLength) -> some View {
        let on = length == option
        // Tapping the picked one again unpicks it.
        return Button { withAnimation(.snappy(duration: 0.3)) { length = on ? nil : option } } label: {
            HStack {
                Text(option.title).font(Typography.font(15.5, weight: .regular)).foregroundStyle(EColor.onSurface)
                Spacer()
                if option == .custom && on {
                    Text(customText)
                        .font(Typography.font(15.5, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct AddBlockedAppsSheet: View {
    @ObservedObject var child: Child
    var onDone: () -> Void

    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var length: BlockLength?
    @State private var customHours = 1
    @State private var customMinutes = 30
    /// Set the first time an app is picked, and never cleared: the lengths
    /// stay put after that, rather than sliding in and out with each tap.
    @State private var showLengths = false
    @State private var warnAlways = false

    private var names: [(id: String, name: String)] {
        selected.compactMap { id in AppCatalog.shared.app(id: id).map { (id, $0.name) } }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        FormShell(title: "Block an app", onCancel: onDone, onSave: save,
                  canSave: !selected.isEmpty && length != nil, saveLabel: "Block") {
            FormField(label: "App") {
                BlockTargetPicker(query: $query, selectedApps: $selected, accent: FormGreen.accent, single: true)
            }
            // How long only means something once there's an app to block.
            if showLengths {
                FormField(label: "For how long") {
                    BlockLengthPicker(length: $length, customHours: $customHours, customMinutes: $customMinutes)
                }
            }
        }
        .onChange(of: selected.isEmpty) { _, empty in if !empty { showLengths = true } }
        .alwaysBlockWarning(isPresented: $warnAlways, childName: child.name) { save(warned: true) }
    }

    private func save() { save(warned: false) }

    private func save(warned: Bool) {
        guard let length, !names.isEmpty else { return }
        // Always first asks the parent to talk with their child.
        if length == .always && !warned { warnAlways = true; return }
        AppBlocking.block(childId: child.id, apps: names,
                          minutes: length.minutes(childId: child.id, custom: customHours * 60 + customMinutes))
        onDone()
    }
}


// MARK: - Before blocking an app for good

/// Picking Always and tapping Block first shows this (2026-11-09, the user's
/// ask): blocking an app for good rarely brings better behaviour; kids can go
/// through withdrawal and the parent's authority starts to wear down, so talk
/// it through with the child first. Block anyway goes ahead; Not now leaves
/// the form as it was. Every time, on the manual sheet and the chat card.
struct AlwaysBlockWarning: View {
    let childName: String
    let onBlock: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(HomeStyle.waiting)
                .frame(width: 48, height: 48)
                .background(HomeStyle.waiting.opacity(0.14), in: Circle())
            Text("Talk with \(childName) first")
                .font(Typography.font(21, weight: .bold))
                .foregroundStyle(EColor.onSurface)
            Text("Blocking an app for good rarely leads to better behavior. Kids can go through withdrawal, and your authority can start to break down. A banned app often becomes the one they want most. Talk it through with \(childName) before you block it.")
                .font(Typography.font(15.5, weight: .regular))
                .foregroundStyle(EColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button(action: onBlock) {
                    Text("Block anyway")
                        .font(Typography.font(16, weight: .bold))
                        .foregroundStyle(EColor.onDangerFill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(EColor.dangerFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(CardPressStyle(haptic: true))
                Button(action: onCancel) {
                    Text("Not now")
                        .font(Typography.font(15.5, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EColor.raised)
    }
}

extension View {
    /// The Always warning as a half card; `onBlock` runs after Block anyway.
    func alwaysBlockWarning(isPresented: Binding<Bool>, childName: String,
                            onBlock: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) {
            AlwaysBlockWarning(childName: childName,
                               onBlock: { isPresented.wrappedValue = false; onBlock() },
                               onCancel: { isPresented.wrappedValue = false })
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.visible)
                .presentationBackground(EColor.raised)
        }
    }
}
