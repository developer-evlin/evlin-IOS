import SwiftUI
import UIKit

// Pulled 1:1 from Evlin_Parent_view/index.html's FORM_GREEN palette (the
// "Virginia" New Task reference) — near-white mint fields, dark forest-green
// heading, brighter leaf-green accent, lavender "Pro" badge. Distinct from
// the app-wide Brand tokens; scoped to the add-task/add-rule sheets only.
private let formBottomAnchorID = "form-bottom-anchor"

enum FormGreen {
    static let fieldBg = Color(hex: "F5FAF7")
    static let title = Color(hex: "0F2115")
    static let accent = Color(hex: "2FA84F")
    static let accentBg = Color(hex: "EAF6ED")
    static let proBg = Color(hex: "EDE7FB")
    static let proText = Color(hex: "7C5CD9")
    static let toggleOff = Color(hex: "B9C4BC")
}

// Bottom-sheet chrome: green "Cancel" top-left, big bold title, content,
// full-width Save pill (accent when enabled, disabled gray otherwise).
struct FormShell<Content: View>: View {
    var title: String
    var onCancel: () -> Void
    var onSave: () -> Void
    var canSave: Bool
    var saveLabel: String = "Save"
    // Opt-in — nil (the default) means no trash icon renders, so every
    // other FormShell caller is unaffected. When set, shows a red trash
    // button top-right of the header, next to Cancel.
    var onDelete: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        // No drag handle here on purpose: these sheets disable interactive
        // swipe-to-dismiss (see .interactiveDismissDisabled() at the call
        // site) so a mid-edit swipe can't silently lose what was typed —
        // Cancel/Save are the only way out, so there's no gesture zone to
        // dodge and "Cancel" can sit right at the top.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    // Bigger than Apple's bare 44pt minimum — the text-only link
                    // read as small/easy-to-miss even at the minimum tap size,
                    // so both the font and the hit area are sized up a bit past
                    // the floor rather than exactly to it.
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())

                Spacer(minLength: 12)

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EColor.danger)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text(title)
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 20)
                    // A "More options" field (the usual reason this needs
                    // scrolling — see MoreOptions below) sits right above
                    // Save, so scrolling to this anchor on keyboard-open
                    // reliably surfaces whatever's actively being typed
                    // without needing per-field FocusState plumbing that
                    // every FormShell call site would otherwise have to add.
                    Color.clear.frame(height: 1).id(formBottomAnchorID)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(formBottomAnchorID, anchor: .bottom)
                    }
                }
            }
            // Every field in these sheets is a plain tap-to-focus text field
            // with no other gesture of its own to protect, so a tap anywhere
            // in the scroll area — not just a drag — dismisses the keyboard,
            // matching the swipe-to-dismiss below.
            .dismissKeyboardOnTap()
            .scrollDismissesKeyboard(.interactively)

            Button(action: onSave) {
                Text(saveLabel)
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(canSave ? .white : EColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canSave ? FormGreen.accent : EColor.outlineVariant.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: canSave ? FormGreen.accent.opacity(0.3) : .clear, radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }
}

struct FormField<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(Typography.font(11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EColor.onSurfaceVariant)
            content
        }
        .padding(.bottom, 18)
    }
}

// The mint-field text input used throughout these forms.
struct FormTextField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Typography.font(15, weight: .regular))
            .foregroundStyle(EColor.onSurface)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// Colored-dot chip — "FOR" / rule-type / category selectors.
struct DotChip: View {
    var label: String
    var color: Color?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(label)
                    .font(Typography.font(13, weight: .bold))
            }
            .foregroundStyle(selected ? FormGreen.accent : EColor.onSurfaceVariant)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(selected ? FormGreen.accentBg : .white)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(selected ? FormGreen.accent : EColor.outlineVariant, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// Simple wrapping HStack for chip rows (SwiftUI has no built-in flow layout
// pre-iOS 16 Layout protocol use here keeps it simple: two rows max via a grid).
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// Mint-boxed date/time fields, side by side (mirrors the native
// <input type="date"> + <input type="time"> pairing).
struct FormDateTimeRow: View {
    @Binding var date: Date
    @Binding var hasDate: Bool

    var body: some View {
        // Already functionally optional (canSave only requires a title —
        // leaving these pickers untouched just leaves hasDate false), but
        // the label didn't say so, and two always-visible, pre-filled-to-
        // today date/time boxes read as required at a glance.
        FormField(label: "When (optional)") {
            HStack(spacing: 8) {
                dateBox
                timeBox
            }
        }
    }

    private var dateBox: some View {
        HStack {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .onChange(of: date) { _, _ in hasDate = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var timeBox: some View {
        HStack {
            DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .onChange(of: date) { _, _ in hasDate = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(FormGreen.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// A single hour/minute picker in the same mint box as every other field —
// tap to get the system's native wheel instead of typing "9:00 AM" and
// hoping it parses the way the calendar list expects. Used for the
// Start/End pair on both the add-event and edit-event forms, since a
// free-text time field is exactly the kind of thing worth making a real
// picker instead of leaving as "type it and hope."
struct FormTimeField: View {
    @Binding var date: Date

    var body: some View {
        DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .padding(.horizontal, 14)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// "Repeats" row: title + purple "Pro" badge, then seven small day-of-week
// bubbles (S M T W T F S) a parent taps individually to build any
// combination — no separate on/off toggle or preset list; an empty
// selection just means "one-time," and picking every weekday (say) reads
// back as "Weekdays" via `repeatDisplayLabel` without that being a distinct
// preset to choose from.
struct RepeatPicker: View {
    @Binding var selectedDays: Set<String>
    @State private var expanded = false

    private var summary: String {
        if selectedDays.isEmpty { return "Does not repeat" }
        let label = repeatDisplayLabel(weekDayCodes.filter { selectedDays.contains($0) }.joined(separator: ","))
        return label.isEmpty ? "Does not repeat" : label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Repeats").font(Typography.font(17, weight: .heavy)).foregroundStyle(FormGreen.title)
                    Text("Pro").font(Typography.font(11, weight: .bold))
                        .foregroundStyle(FormGreen.proText)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(FormGreen.proBg).clipShape(Capsule())
                    Spacer()
                    Text(summary)
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: 8) {
                    ForEach(Array(weekDayCodes.enumerated()), id: \.offset) { i, code in
                        let selected = selectedDays.contains(code)
                        Button {
                            if selected { selectedDays.remove(code) } else { selectedDays.insert(code) }
                        } label: {
                            Text(weekDayInitials[i])
                                .font(Typography.font(13, weight: .bold))
                                .foregroundStyle(selected ? .white : EColor.onSurfaceVariant)
                                .frame(width: 34, height: 34)
                                .background(selected ? FormGreen.accent : FormGreen.fieldBg)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 18)
    }
}

// Collapsed-by-default disclosure — tucks secondary fields behind a tap.
struct MoreOptions<Content: View>: View {
    // Fires only on open -> closed, not the reverse — a caller uses this to
    // discard whatever was entered in a field that only exists while this
    // is expanded (see AddTaskSheet's whenField), on the idea that hiding
    // the section again means "never mind," not "keep it but out of sight."
    var onCollapse: (() -> Void)? = nil
    @State private var open = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    open.toggle()
                    if !open { onCollapse?() }
                }
            } label: {
                HStack {
                    Text("More options").font(Typography.font(15, weight: .heavy)).foregroundStyle(EColor.onSurface)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 14)
                .overlay(Divider(), alignment: .top)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - Block target picker

enum BlockTargetTab: String, CaseIterable { case apps = "Apps", categories = "Categories" }

// Apps/Categories tab switcher + search + rows, picking from the shared
// mockAppCatalog/mockCategoryCatalog (AppCatalogData.swift). Used both by
// chat's one-off "Block an app" card and ScreenProfile's standing "Blocked
// Apps" rule, so a parent picks from the identical list either way. Only
// the top 3 of whichever tab is active ever show without a query — search
// is the only way to reach the rest, not a "show all" expand, so there's
// one clear path once the shortlist doesn't have what a parent wants.
struct BlockTargetPicker: View {
    @Binding var tab: BlockTargetTab
    @Binding var query: String
    @Binding var selectedApps: Set<UUID>
    @Binding var selectedCategories: Set<UUID>
    var accent: Color = EColor.danger

    @Environment(\.isEnabled) private var isEnabled

    private let topCount = 3

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filteredApps: [MockApp] {
        guard isSearching else { return mockAppCatalog }
        return mockAppCatalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredCategories: [MockCategory] {
        guard isSearching else { return mockCategoryCatalog }
        return mockCategoryCatalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var visibleApps: [MockApp] {
        isSearching ? filteredApps : Array(filteredApps.prefix(topCount))
    }

    private var visibleCategories: [MockCategory] {
        isSearching ? filteredCategories : Array(filteredCategories.prefix(topCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(BlockTargetTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(Typography.font(12.5, weight: .semibold))
                            .foregroundStyle(tab == t ? .white : EColor.onSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(tab == t ? accent : EColor.surfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(EColor.onSurfaceVariant)
                TextField(tab == .apps ? "Search apps" : "Search categories", text: $query)
                    .font(Typography.font(13, weight: .regular))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(EColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if tab == .apps {
                VStack(spacing: 6) {
                    ForEach(visibleApps) { app in
                        targetRow(
                            icon: app.icon, color: app.color, title: app.name, subtitle: app.bundleID,
                            bundleID: app.bundleID, selected: selectedApps.contains(app.id)
                        ) { toggleApp(app) }
                    }
                    if !isSearching, filteredApps.count > topCount {
                        searchHint(noun: "app")
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleCategories) { cat in
                        targetRow(
                            icon: cat.icon, color: cat.color, title: cat.name, subtitle: nil,
                            selected: selectedCategories.contains(cat.id)
                        ) { toggleCategory(cat) }
                    }
                    if !isSearching, filteredCategories.count > topCount {
                        searchHint(noun: "category")
                    }
                }
            }
        }
    }

    private func toggleApp(_ app: MockApp) {
        guard isEnabled else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            if selectedApps.contains(app.id) { selectedApps.remove(app.id) } else { selectedApps.insert(app.id) }
        }
    }

    private func toggleCategory(_ cat: MockCategory) {
        guard isEnabled else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            if selectedCategories.contains(cat.id) { selectedCategories.remove(cat.id) } else { selectedCategories.insert(cat.id) }
        }
    }

    // Bigger than the old row (44pt icon vs 34, more padding, a filled
    // circle instead of a small square) plus a colored border on top of the
    // tint fill when selected — a parent picking an app to block should be
    // able to hit the row without aiming, and see at a glance what's
    // already picked without reading each checkbox individually.
    private func targetRow(icon: String, color: Color, title: String, subtitle: String?, bundleID: String? = nil, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let bundleID {
                    AppIconView(bundleID: bundleID, fallbackIcon: icon, fallbackColor: color)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(color)
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.white))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurface)
                    if let subtitle {
                        Text(subtitle).font(Typography.font(11, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23))
                    .foregroundStyle(selected ? accent : EColor.outlineVariant)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(selected ? accent.opacity(0.08) : EColor.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? accent.opacity(0.5) : EColor.outlineVariant, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // Not a button — search above is the only way past the top 3, so this
    // just tells a parent that path exists instead of offering a second one.
    private func searchHint(noun: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            Text("Don't see it? Search for the \(noun) above.")
                .font(Typography.font(12.5, weight: .medium))
        }
        .foregroundStyle(EColor.onSurfaceVariant)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }
}
