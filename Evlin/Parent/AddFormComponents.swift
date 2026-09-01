import SwiftUI

// Pulled 1:1 from Evlin_Parent_view/index.html's FORM_GREEN palette (the
// "Virginia" New Task reference) — near-white mint fields, dark forest-green
// heading, brighter leaf-green accent, lavender "Pro" badge. Distinct from
// the app-wide Brand tokens; scoped to the add-task/add-rule sheets only.
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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 20)
            }

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
    @State private var open = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { open.toggle() }
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
