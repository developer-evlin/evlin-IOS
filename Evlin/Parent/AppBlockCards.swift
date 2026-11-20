import SwiftUI

/// Blocking an app from chat: the agent drafts it (which app, how long, and
/// why), and the parent can change either before tapping Block. Compact: the
/// app on one line with Change, the lengths as chips. The lengths and the
/// save are the manual sheet's (AddBlockedAppsSheet.swift: BlockLength,
/// AppBlocking.block), so a block is the same however it was made. Nothing
/// is blocked until Block.
struct AppBlockDraftCard: View {
    let childId: String
    var done: Bool = false
    /// Called with the app's name and how long ("For 1 hour").
    var onBlocked: (_ app: String, _ length: String) -> Void

    @State private var selected: Set<String>
    @State private var query = ""
    @State private var length: BlockLength?
    @State private var customHours: Int
    @State private var customMinutes: Int
    @State private var submitted: Bool
    @State private var warnAlways = false
    private let draftName: String?

    init(draft: BlockDraft, childId: String, done: Bool = false,
         onBlocked: @escaping (_ app: String, _ length: String) -> Void) {
        self.childId = childId
        self.done = done
        self.onBlocked = onBlocked
        draftName = draft.appName
        _selected = State(initialValue: draft.appId.map { [$0] } ?? [])
        _length = State(initialValue: draft.length)
        _customHours = State(initialValue: draft.customMinutes / 60)
        _customMinutes = State(initialValue: (draft.customMinutes % 60) / 5 * 5)
        _submitted = State(initialValue: done)
    }

    private var apps: [(id: String, name: String)] {
        selected.map { id in (id, AppCatalog.shared.app(id: id)?.name ?? (draftName ?? "App")) }
            .sorted { $0.name < $1.name }
    }

    private var ready: Bool { !selected.isEmpty && length != nil && !submitted }

    @State private var showPicker = false

    private var appName: String? { apps.first?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The app, as one line: its icon and name, with Change to pick
            // another. The full app list only opens on Change (or when the
            // agent couldn't name one), so the card stays short.
            HStack(spacing: 12) {
                if let appName {
                    AppIconView(appName: appName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block \(appName)")
                            .font(ChatType.strong(16))
                            .foregroundStyle(EColor.onSurface)
                        Text(summary)
                            .font(ChatType.label(13))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }
                } else {
                    Image(systemName: "nosign").font(.system(size: 17)).foregroundStyle(EColor.danger)
                    Text("Block an app").font(ChatType.strong(16)).foregroundStyle(EColor.onSurface)
                }
                Spacer(minLength: 8)
                if submitted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.greenDeep)
                        .transition(.scale.combined(with: .opacity))
                } else if appName != nil {
                    Button(showPicker ? "Done" : "Change") {
                        withAnimation(.easeOut(duration: 0.2)) { showPicker.toggle() }
                    }
                    .font(ChatType.label(14))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .buttonStyle(PressedFadeStyle())
                }
            }

            if showPicker || appName == nil {
                BlockTargetPicker(query: $query, selectedApps: $selected, accent: FormGreen.accent, single: true)
            }

            // The same five lengths as the manual sheet, as chips.
            FlowLayout(spacing: 8) {
                ForEach(BlockLength.allCases, id: \.self) { option in
                    chip(option)
                }
            }
            if length == .custom { customWheels }

            Button(action: block) {
                Text(submitted ? "Blocked" : "Block")
                    .font(ChatType.label(15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(ready || submitted ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressedSurfaceStyle())
            .disabled(!ready)
            .accessibilityHint(selected.isEmpty ? "Pick an app first" : length == nil ? "Pick how long first" : "")
        }
        .padding(16)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EColor.outlineVariant))
        .disabled(submitted)
        .task { await AppCatalog.shared.load() }
        .onChange(of: selected) { _, now in if !now.isEmpty, appName != nil { showPicker = false } }
        .alwaysBlockWarning(isPresented: $warnAlways,
                            childName: FamilyStore.children.first { $0.id == childId }?.name ?? "your child") {
            block(warned: true)
        }
    }

    /// "For 1 hour", "For the rest of today", "Always".
    private var summary: String {
        switch length {
        case .thirtyMinutes: return "For 30 minutes"
        case .oneHour: return "For 1 hour"
        case .custom: return "For \(customText)"
        case .restOfToday: return "For the rest of today"
        case .always: return "Always"
        case nil: return "Pick how long"
        }
    }

    private var customText: String {
        switch (customHours, customMinutes) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) h"
        case (let h, let m): return "\(h) h \(m) min"
        }
    }

    private func chip(_ option: BlockLength) -> some View {
        let on = length == option
        return Button { length = on ? nil : option } label: {
            Text(option == .custom && on ? customText : option.title)
                .font(ChatType.label(14))
                .foregroundStyle(on ? .white : EColor.onSurface)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(on ? Brand.greenDeep : EColor.surfaceContainerHigh, in: Capsule())
        }
        .buttonStyle(PressedSurfaceStyle())
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Hours and minutes, only while Custom is picked.
    private var customWheels: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: $customHours) {
                ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
            }
            Picker("Minutes", selection: $customMinutes) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 120)
        .onChange(of: customHours) { _, h in if h == 0 && customMinutes == 0 { customMinutes = 5 } }
        .onChange(of: customMinutes) { _, m in if customHours == 0 && m == 0 { customMinutes = 5 } }
    }

    private func block() { block(warned: false) }

    private func block(warned: Bool) {
        guard let length, ready else { return }
        // Always first asks the parent to talk with their child.
        if length == .always && !warned { warnAlways = true; return }
        AppBlocking.block(childId: childId, apps: apps,
                          minutes: length.minutes(childId: childId, custom: customHours * 60 + customMinutes))
        withAnimation(.easeOut(duration: 0.2)) { submitted = true }
        let name = apps.first?.name ?? "the app"
        onBlocked(name, summary)
    }

    /// "YouTube", "YouTube and Roblox", "YouTube, Roblox and TikTok".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "apps"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
