import SwiftUI
import UIKit

// Pulled 1:1 from Evlin_Parent_view/index.html's FORM_GREEN palette (the
// "Virginia" New Task reference) — near-white mint fields, dark forest-green
// heading, brighter leaf-green accent, lavender "Pro" badge. Distinct from
// the app-wide Brand tokens; scoped to the add-task/add-rule sheets only.
private let formBottomAnchorID = "form-bottom-anchor"
private let formTopAnchorID = "form-top-anchor"

// Lets a field buried inside FormShell's content (MoreOptions expanding,
// TaskDeadlineField revealing its time picker, a multi-line Notes/"What
// to do" field growing another line) ask the sheet to re-run its
// keyboard-avoidance scroll after growing taller. Without this, the
// scroll-to-bottom only ever fires once, on keyboardWillShowNotification —
// content that grows *after* that has no way to pull the view back down to
// it, so it ends up crammed against the fixed Save button instead of fully
// visible.
//
// A GeometryReader-based height tracker was tried here instead (measure
// the content's own height via .background(GeometryReader{...}) +
// onPreferenceChange, so growth of any kind would self-report) — it reads
// as more general, but a GeometryReader placed inside a ScrollView's
// content interferes with that ScrollView's own content-size measurement:
// scrollTo(anchor: .bottom) started undershooting and leaving real fields
// (a still-open "What to do" box) hidden behind the Save button, the exact
// bug this mechanism exists to prevent. Explicit triggers at the specific
// places content actually grows are more code, but they don't fight the
// scroll view's own layout math.
private struct ScrollFormToBottomKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var scrollFormToBottom: () -> Void {
        get { self[ScrollFormToBottomKey.self] }
        set { self[ScrollFormToBottomKey.self] = newValue }
    }
}

// The bottom-anchor mechanism above only ever pulls the view *down* to
// reveal newly-grown content — it has no notion of "scroll back up to
// whatever's now focused." That breaks the moment a parent expands "More
// options" (scrolling down), then taps back into the very first field
// (Title/Task name): nothing scrolls back up for it, so it can end up
// exactly as cramped against a since-grown form as the bottom field used
// to be. This is the same idea, aimed at the top anchor instead, for the
// one field that's always first in every one of these forms.
private struct ScrollFormToTopKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var scrollFormToTop: () -> Void {
        get { self[ScrollFormToTopKey.self] }
        set { self[ScrollFormToTopKey.self] = newValue }
    }
}

// The form's first field (the name) reports when it has focus, so the
// keyboard keeps it in view instead of scrolling down to the last field.
private struct FormTopFieldFocusKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
    var formTopFieldFocused: (Bool) -> Void {
        get { self[FormTopFieldFocusKey.self] }
        set { self[FormTopFieldFocusKey.self] = newValue }
    }
}

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
    // A second, compact copy of this button used to live in the keyboard's
    // own accessory bar, hidden/shown opposite this one so only one was
    // ever meant to be on screen at a time. In practice that turned into
    // three rounds of real bugs (a broken toolbar-button style, a fixed
    // "stuck visible" state when the keyboard was dismissed interactively,
    // general confusion about which button was the real one) for a modest
    // space win in one edge case (keyboard up *and* "More options" fully
    // expanded). One button, always in the same place, is worth more than
    // that edge case — the scroll-to-bottom mechanism below still brings it
    // into view along with whatever's actively being typed.
    @State private var keyboardVisible = false
    @State private var topFieldFocused = false

    var body: some View {
        // No drag handle here on purpose: these sheets disable interactive
        // swipe-to-dismiss (see .interactiveDismissDisabled() at the call
        // site) so a mid-edit swipe can't silently lose what was typed —
        // Cancel/Save are the only way out, so there's no gesture zone to
        // dodge and "Cancel" can sit right at the top.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // A close button in the iOS sheet style: a small x on a soft
                // circle, with a full 48pt tap area around it.
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(width: 34, height: 34)
                        .background(EColor.surfaceContainerHigh, in: Circle())
                        .frame(width: 48, height: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")

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
                    Color.clear.frame(height: 1).id(formTopAnchorID)
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 20)
                    // A "More options" field (the usual reason this needs
                    // scrolling — see MoreOptions below) sits right above
                    // Save, so scrolling to this anchor on keyboard-open
                    // reliably surfaces whatever's actively being typed
                    // without needing per-field FocusState plumbing that
                    // every FormShell call site would otherwise have to add.
                    Color.clear.frame(height: 24).id(formBottomAnchorID)
                }
                // keyboardWillShow/keyboardWillHide (the discrete pair this
                // used to rely on) go out of sync the moment a keyboard is
                // dismissed *interactively* (dragging the scroll content
                // down, which .scrollDismissesKeyboard(.interactively)
                // below explicitly enables) — that gesture doesn't reliably
                // fire keyboardWillHide, so keyboardVisible could get stuck
                // true forever. keyboardWillChangeFrame fires for every way
                // the keyboard's frame can change, interactive dismissal
                // included, and carries the actual frame — checking that
                // directly instead of trusting a separate "did it hide"
                // event is what actually stays correct.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    let visible = frame.origin.y < UIScreen.main.bounds.height
                    guard visible != keyboardVisible else { return }
                    keyboardVisible = visible
                    if visible {
                        // Typing the name: keep the top in view. Any later
                        // field: bring the bottom of the form above the keys.
                        withAnimation(.easeOut(duration: 0.25)) {
                            if topFieldFocused {
                                proxy.scrollTo(formTopAnchorID, anchor: .top)
                            } else {
                                proxy.scrollTo(formBottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                }
                .environment(\.scrollFormToBottom, {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(formBottomAnchorID, anchor: .bottom)
                    }
                })
                .environment(\.formTopFieldFocused) { topFieldFocused = $0 }
                .environment(\.scrollFormToTop, {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(formTopAnchorID, anchor: .top)
                    }
                })
            }
            // Every field in these sheets is a plain tap-to-focus text field
            // with no other gesture of its own to protect, so a tap anywhere
            // in the scroll area dismisses the keyboard too.
            .dismissKeyboardOnTap()
            // .immediately, not .interactively — interactively ties the
            // keyboard's dismissal to the same continuous drag a scroll
            // gesture starts with, which is exactly the drag a sheet's own
            // pan-to-dismiss recognizer is watching for. Even with
            // .interactiveDismissDisabled() set on this sheet (see the call
            // site), a fast/aggressive scroll-down starting from a focused
            // field could still let that drag bleed through and dismiss the
            // whole sheet — silently discarding whatever was typed — because
            // the two pan gestures aren't fully isolated from each other.
            // .immediately drops the keyboard the instant a drag begins
            // instead of tracking it, so there's no longer a continuous
            // interactive pan for that ambiguity to happen in.
            .scrollDismissesKeyboard(.immediately)

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
    // Opt-in — every FormShell form's first field (Title/Task name) sets
    // this so tapping back into it after scrolling down for a later field
    // (MoreOptions, a date picker) brings it back into comfortable view,
    // instead of leaving it exactly as cramped against the rest of the
    // grown form as the field that pulled the scroll down in the first
    // place. Every other field leaves this off — they're not always first,
    // and the bottom-anchor scroll already covers them growing/appearing.
    var scrollToTopOnFocus: Bool = false
    @FocusState private var focused: Bool
    @Environment(\.scrollFormToTop) private var scrollFormToTop
    @Environment(\.formTopFieldFocused) private var formTopFieldFocused

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Typography.font(15, weight: .regular))
            .foregroundStyle(EColor.onSurface)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                guard scrollToTopOnFocus else { return }
                formTopFieldFocused(isFocused)
                if isFocused { scrollFormToTop() }
            }

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

// A task's deadline, as a time of day only. Every task form uses it: the
// day is always decided elsewhere (Home's Today / Tomorrow tab, the day
// open on the calendar, or the task's own day when editing), so it never
// asks for a date. "Add a deadline" reveals a time picker; ✕ removes it,
// leaving the task with no set time that day.
struct TaskDeadlineField: View {
    @Binding var hasDeadline: Bool
    @Binding var time: Date
    // The task's day: where the picker starts depends on it.
    var day: Date
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    // Where the picker starts when a deadline is added: the next whole
    // hour if that's still on the task's day, else 6 PM that day.
    static func defaultTime(on day: Date) -> Date {
        let cal = Calendar.current
        let nextHour = cal.date(byAdding: .hour, value: 1, to: Date()).flatMap {
            cal.date(bySetting: .minute, value: 0, of: $0)
        } ?? Date()
        if cal.isDate(nextHour, inSameDayAs: day) { return nextHour }
        return cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
    }

    // The picked time on the task's day: the moment the task is due.
    static func moment(_ time: Date, on day: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day) ?? day
    }

    var body: some View {
        FormField(label: "Deadline") {
            if hasDeadline {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FormGreen.accent)
                        Text("Due by")
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(EColor.onSurface)
                        Spacer(minLength: 4)
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .padding(.leading, 14).padding(.trailing, 8)
                    .frame(height: 48)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { hasDeadline = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .frame(width: 48, height: 48)
                            .background(FormGreen.fieldBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove deadline")
                }
            } else {
                Button {
                    time = Self.defaultTime(on: day)
                    withAnimation(.easeInOut(duration: 0.16)) { hasDeadline = true }
                    // The added row needs a beat to reach the ScrollView's
                    // content size before the form can scroll to it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scrollFormToBottom() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                        Text("Add a deadline").font(Typography.font(14, weight: .semibold))
                    }
                    .foregroundStyle(FormGreen.accent)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
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
    // Lets a caller open this pre-expanded when there's already something
    // inside worth seeing without an extra tap (e.g. editing a task that
    // already has a due date) — new/empty forms still default closed.
    var startOpen: Bool = false
    @State private var open: Bool
    @ViewBuilder var content: Content
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    init(startOpen: Bool = false, @ViewBuilder content: () -> Content) {
        self.startOpen = startOpen
        self.content = content()
        _open = State(initialValue: startOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { open.toggle() }
                if open {
                    // Combining this with the toggle in one withAnimation
                    // was tried and measured to undershoot on a real
                    // device — MoreOptions is nested below the ScrollView,
                    // and scrollTo fired synchronously inside that block
                    // ran before the newly-revealed content's height had
                    // actually propagated up to the ScrollView. This delay
                    // is the version that's actually been verified to
                    // work; don't remove it without re-verifying.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        scrollFormToBottom()
                    }
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
                // A Rectangle, not Divider: in an HStack's overlay a
                // Divider draws vertical, down the middle of the row.
                .overlay(alignment: .top) {
                    Rectangle().fill(EColor.outlineVariant).frame(height: 0.5)
                }
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - Add Task form

// The one Add Task form, used by Home and the calendar: name, which child
// (only when not already fixed), Repeats, and under More options a
// deadline time and instructions. The day comes from the caller.
struct AddTaskFormFields: View {
    var title: String
    var saveLabel: String
    // nil shows the For picker (Calendar's case); a real child hides it
    // (a profile's add-task, already scoped to that one child).
    var fixedChild: Child?
    @Binding var taskTitle: String
    @Binding var personId: String
    @Binding var whatToDo: String
    @Binding var repeatDays: Set<String>
    @Binding var hasDeadline: Bool
    @Binding var deadline: Date
    // The day the task lands on.
    var day: Date
    var canSave: Bool
    var onCancel: () -> Void
    var onSave: () -> Void
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    var body: some View {
        FormShell(title: title, onCancel: onCancel, onSave: onSave, canSave: canSave, saveLabel: saveLabel) {
            FormField(label: fixedChild == nil ? "Title" : "Task name") {
                FormTextField(placeholder: "e.g. Make your bed", text: $taskTitle, scrollToTopOnFocus: true)
            }
            if fixedChild == nil {
                // Which child. Evlin manages the children only, so the
                // choices are the children (CalendarData.people).
                FormField(label: "For") {
                    FlowChips {
                        ForEach(CalendarData.people) { p in
                            DotChip(label: p.name, color: p.color, selected: personId == p.id) { personId = p.id }
                        }
                    }
                }
            }
            RepeatPicker(selectedDays: $repeatDays)
            MoreOptions {
                TaskDeadlineField(hasDeadline: $hasDeadline, time: $deadline, day: day)
                FormField(label: "What to do") {
                    TextField("Instructions…", text: $whatToDo, axis: .vertical)
                        .font(Typography.font(15, weight: .regular))
                        .lineLimit(3...5)
                        .padding(14)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        // Growing to a new line while the keyboard is up is
                        // the same "content got taller" case MoreOptions'
                        // own toggle handles above — this field just grows
                        // from typing instead of a tap.
                        .onChange(of: whatToDo) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollFormToBottom()
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Block target picker

// Search + rows, picking from Evlin's app catalog (AppCatalog, loaded from the backend).
// Used both by chat's one-off "Block an app" card and ScreenProfile's
// standing "Blocked Apps" rule, so a parent picks from the identical list
// either way. Only the top 3 ever show without a query — search is the only
// way to reach the rest, not a "show all" expand, so there's one clear path
// once the shortlist doesn't have what a parent wants.
//
// Real apps only — no "Categories" tab. A category ("Social Media", "Games")
// had no real bundle ID behind it, so it could only ever show a generic
// SF Symbol tile instead of the app's actual icon the way every real app
// here does via AppIconView/ITunesLookup. Mixing a handful of fake-icon
// category rows in with real ones read as inconsistent — better to only
// offer what this picker can actually show a real icon for.
struct BlockTargetPicker: View {
    @Binding var query: String
    /// Catalog app ids.
    @Binding var selectedApps: Set<String>
    var accent: Color = EColor.danger

    @Environment(\.isEnabled) private var isEnabled

    private let topCount = 3

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var catalog: [ApiApp] { AppCatalog.shared.apps }

    /// Aliases count too: searching "yt" finds YouTube.
    private var filteredApps: [ApiApp] {
        guard isSearching else { return catalog }
        return catalog.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
                || app.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var visibleApps: [ApiApp] {
        isSearching ? filteredApps : Array(filteredApps.prefix(topCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(EColor.onSurfaceVariant)
                TextField("Search apps", text: $query)
                    .font(Typography.font(13, weight: .regular))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(EColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 6) {
                ForEach(visibleApps) { app in
                    targetRow(title: app.name, selected: selectedApps.contains(app.id)) { toggleApp(app) }
                }
                if !isSearching, filteredApps.count > topCount {
                    searchHint(noun: "app")
                }
            }
        }
        // Loads the catalog, then warms every app's icon — a few dozen
        // apps, so this is cheap, and typing into search never waits on a
        // fresh lookup for anything that could match. See
        // ITunesLookup.prefetchAll.
        .task {
            await AppCatalog.shared.load()
            ITunesLookup.prefetchAll(appNames: AppCatalog.shared.apps.map(\.name))
        }
    }

    private func toggleApp(_ app: ApiApp) {
        guard isEnabled else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            if selectedApps.contains(app.id) { selectedApps.remove(app.id) } else { selectedApps.insert(app.id) }
        }
    }

    // Bigger than the old row (44pt icon vs 34, more padding, a filled
    // circle instead of a small square) plus a colored border on top of the
    // tint fill when selected — a parent picking an app to block should be
    // able to hit the row without aiming, and see at a glance what's
    // already picked without reading each checkbox individually. No bundle
    // ID line under the name any more — a real icon now does the job that
    // was standing in for (telling two similarly-named apps apart), and
    // a raw identifier like "com.zhiliaoapp.musically" routinely wrapped to
    // two lines and crowded the row below it.
    private func targetRow(title: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AppIconView(appName: title)
                Text(title).font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurface)
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
