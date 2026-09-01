import SwiftUI

// Ported from Views/Settings/LockListManagerView.swift. The source manages a
// FamilyControls/DeviceActivity catalog synced over APIClient; this prototype
// has none of that, so it's a flat local list of apps/categories/lists the
// parent can add a name to or remove — same three-section layout and copy,
// no real lock enforcement behind it.
struct SettingsLockListManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apps = ["Instagram", "YouTube", "Roblox"]
    @State private var categories = ["Games", "Social"]
    @State private var lists = ["School Nights"]

    @State private var addTarget: AddTarget?
    @State private var newEntryName = ""

    private enum AddTarget: Identifiable {
        case app, category, list
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .app: return "Add app"
            case .category: return "Add category"
            case .list: return "Create list"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                addActions

                section(title: "Apps", count: apps.count,
                        description: "Apps Evlin can recognize by name, show usage insights for, and lock or block when needed.",
                        emptyText: "No apps saved yet. Tap \u{201c}Add app\u{201d}.") {
                    ForEach(Array(apps.enumerated()), id: \.offset) { index, name in
                        if index > 0 { rowDivider }
                        targetRow(name) { apps.remove(at: index) }
                    }
                }

                section(title: "Categories", count: categories.count,
                        description: "Broad categories like Games or Social. Locking a category covers matching apps now and apps installed later.",
                        emptyText: "No categories saved yet. Tap \u{201c}Add category\u{201d}.") {
                    ForEach(Array(categories.enumerated()), id: \.offset) { index, name in
                        if index > 0 { rowDivider }
                        targetRow(name) { categories.remove(at: index) }
                    }
                }

                section(title: "Lists", count: lists.count,
                        description: "Custom groups of apps and categories — use a list when one rule should lock a mix, e.g. YouTube + Games.",
                        emptyText: "No lists yet. Group added apps and categories with \u{201c}Create list\u{201d}.") {
                    ForEach(Array(lists.enumerated()), id: \.offset) { index, name in
                        if index > 0 { rowDivider }
                        targetRow(name) { lists.remove(at: index) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(EColor.surface.ignoresSafeArea())
        .navigationTitle("App Controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .alert(addTarget?.title ?? "", isPresented: Binding(get: { addTarget != nil }, set: { if !$0 { addTarget = nil } })) {
            TextField("Name", text: $newEntryName)
            Button("Cancel", role: .cancel) { addTarget = nil; newEntryName = "" }
            Button("Save") {
                let trimmed = newEntryName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    switch addTarget {
                    case .app: apps.append(trimmed)
                    case .category: categories.append(trimmed)
                    case .list: lists.append(trimmed)
                    case .none: break
                    }
                }
                addTarget = nil
                newEntryName = ""
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EColor.primary)
                Image(systemName: "lock.shield.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("App Controls").font(Typography.font(16, weight: .bold)).foregroundStyle(EColor.onSurface)
                Text("Apps support usage insights and per-app time limits; categories and lists help lock broader sets of apps.")
                    .font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
    }

    private var addActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                addButton(title: "Add app", systemImage: "plus.app.fill", tint: EColor.primary) { addTarget = .app }
                addButton(title: "Add category", systemImage: "square.grid.2x2.fill", tint: EColor.success) { addTarget = .category }
            }
            addButton(title: "Create list", systemImage: "rectangle.stack.badge.plus", tint: Color(hex: "7C6FF7")) { addTarget = .list }
        }
    }

    private func addButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                Text(title).font(Typography.font(14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, description: String, emptyText: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(Typography.font(12, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant)
                Text("\(count)")
                    .font(Typography.font(10, weight: .bold))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(EColor.outlineVariant.opacity(0.5)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            Text(description)
                .font(Typography.font(12, weight: .regular))
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if count == 0 {
                    Text(emptyText)
                        .font(Typography.font(14, weight: .regular))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    content()
                }
            }
            .background(EColor.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
        }
    }

    private var rowDivider: some View {
        Divider().overlay(EColor.outlineVariant).padding(.leading, 16)
    }

    private func targetRow(_ name: String, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(name).font(Typography.font(15, weight: .regular)).foregroundStyle(EColor.onSurface)
            Spacer(minLength: 12)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(EColor.danger)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
