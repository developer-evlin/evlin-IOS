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
    // A step deeper than the Alabaster page (2026-11-14: #EFECE5, made for
    // the cream page, all but vanished on it).
    static let fieldBg = Color(light: "EFEFF4", dark: "2A2E35")
    static let title = Color(light: "0F2115", dark: "E4E4E6")
    /// The main app's button green (Create task, Approve, Add habit, the
    /// day pills, the Pro badge). Onboarding keeps its own brighter #3FCE64
    /// (2026-11-15: the mascot green here too was tried and reversed the
    /// same day, the user's call).
    static let accent = Color(light: "2FA84F", dark: "3A9257")
    /// Approve's green (the review card, the habit's half card, the story
    /// viewer): the button green, the same as Create task and Add habit
    /// (2026-11-16, the user's call: the done ticks' lighter #34C759, from
    /// 2026-11-15, didn't match Add task on the cream).
    static let approve = accent
    static let accentBg = Color(light: "EAF6ED", dark: "17301F")
    /// The Pro badge: the Create / Approve green, white words (2026-11-14,
    /// the user's call: a pale wash with green words didn't match).
    static let proBg = accent
    static let proText = Color.white
    static let toggleOff = Color(hex: "B9C4BC")
}

// Bottom-sheet chrome: green "Cancel" top-left, big bold title, content,
// full-width Save pill (accent when enabled, disabled gray otherwise).
extension View {
    /// A sheet you leave only by its own close button (or its Save): no
    /// swipe down, and no grab line suggesting one, so what's been typed
    /// can't be lost to a stray drag.
    func closesOnlyWithButton(_ on: Bool = true) -> some View {
        interactiveDismissDisabled(on)
            .presentationDragIndicator(on ? .hidden : .visible)
    }
}

/// A sheet's close button: a plain x at the right of the header (adding or
/// editing alike), with a full 48pt tap area.
struct SheetCloseButton: View {
    var label: String = "Close"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The delete button every edit sheet uses: a plain trash can drawn like the
/// close button (same ink, a lighter stroke so its lines don't look heavy),
/// at the left of the header across from it. It always asks first (the
/// caller's confirm), which is where the red is.
struct SheetDeleteButton: View {
    var label: String = "Delete"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 20))
                .foregroundStyle(.red)
                .frame(width: 48, height: 48, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Swipe down to close

/// Hears a swipe-down that SwiftUI held back (interactiveDismissDisabled),
/// so the question can be asked. It listens to the sheet's own drag rather
/// than taking over the sheet's delegate: SwiftUI owns that, and replacing
/// it made SwiftUI present the sheet afresh, emptying the form.
private struct DismissAttemptObserver: UIViewControllerRepresentable {
    var hold: Bool
    var onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hold = hold
        controller.onAttempt = onAttempt
    }

    final class Controller: UIViewController {
        var hold = false
        var onAttempt: () -> Void = {}
        private var listening: [UIGestureRecognizer] = []

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard listening.isEmpty else { return }
            // The sheet's drag lives on the sheet's view or one around it,
            // never on the form's own scroll views inside.
            var view: UIView? = view
            while let v = view {
                for pan in v.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer {
                    pan.addTarget(self, action: #selector(dragged(_:)))
                    listening.append(pan)
                }
                view = v.superview
            }
        }

        @objc private func dragged(_ pan: UIPanGestureRecognizer) {
            guard hold, pan.state == .ended, let v = pan.view else { return }
            // A clear pull down, not a nudge: about what would have closed it.
            if pan.translation(in: v).y > 80 || pan.velocity(in: v).y > 800 { onAttempt() }
        }

        deinit { listening.forEach { $0.removeTarget(self, action: nil) } }
    }
}

struct FormShell<Content: View>: View {
    var title: String
    var onCancel: () -> Void
    var onSave: () -> Void
    var canSave: Bool
    var saveLabel: String = "Save"
    // Opt-in for edit forms: SheetDeleteButton at the left of the header.
    var onDelete: (() -> Void)? = nil
    var deleteTitle: String = "Delete"
    /// Something's been typed or changed. Off: a swipe down closes the
    /// sheet. On: the swipe is held and the parent is asked whether to
    /// discard (onCancel) or keep editing, as Calendar and Reminders do.
    var hasChanges: Bool = false
    /// A step back to what came before the form, at the left of the header.
    var onBack: (() -> Void)? = nil
    /// Off when the sheet draws its own header above the form (New task's tabs).
    var showsHeader: Bool = true
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
    @State private var askDiscard = false

    var body: some View {
        // Swipes away like any sheet; once something's typed or changed the
        // swipe is held and asks first (hasChanges, at the bottom), so a
        // stray swipe never loses what was typed.
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                // Delete on the left when editing; close stays on the right.
                HStack {
                    if let onDelete { SheetDeleteButton(label: deleteTitle, action: onDelete) }
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(FormGreen.title)
                                .frame(width: 48, height: 48, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    }
                    Spacer(minLength: 12)
                    // With changes, the ✕ asks the swipe's question first
                    // (2026-11-18, the user's call), the keyboard down so
                    // it's seen where Save was.
                    SheetCloseButton(label: "Cancel") {
                        guard hasChanges else { return onCancel() }
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        withAnimation(.spring(duration: 0.3, bounce: 0)) { askDiscard = true }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

                if !title.isEmpty {
                    Text(title)
                        .font(Typography.font(26, weight: .heavy))
                        .foregroundStyle(FormGreen.title)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                }
            }

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

            // The swipe's question takes the button's place, inside the
            // sheet: no pop-up over the form. (One presented from this
            // sheet also made SwiftUI present the sheet afresh, emptied.)
            Group {
                if askDiscard {
                    discardChoice
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
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
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        // Closes with a swipe down at iOS's own threshold, like any sheet.
        // With changes the swipe is held and the parent is asked first.
        .presentationBackground(EColor.surface)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasChanges)
        .background(DismissAttemptObserver(hold: hasChanges) {
            withAnimation(.spring(duration: 0.3, bounce: 0)) { askDiscard = true }
        })
        .sensoryFeedback(.impact(flexibility: .soft), trigger: askDiscard) { _, asking in asking }
    }

    private var discardChoice: some View {
        VStack(spacing: 10) {
            Text("Discard your changes?")
                .font(Typography.font(13, weight: .semibold))
                .foregroundStyle(EColor.onSurfaceVariant)
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Discard")
                        .font(Typography.font(15, weight: .heavy))
                        .foregroundStyle(EColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(EColor.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0)) { askDiscard = false }
                } label: {
                    Text("Keep editing")
                        .font(Typography.font(15, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
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
    /// The keyboard comes up as the field arrives (writing a task of one's own).
    var focusOnAppear: Bool = false
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
            .onAppear {
                guard focusOnAppear else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
            }
            .onChange(of: focused) { _, isFocused in
                guard scrollToTopOnFocus else { return }
                formTopFieldFocused(isFocused)
                if isFocused { scrollFormToTop() }
            }

    }
}

/// New task's name: a blank canvas, text with no box around it. No clear
/// button: the sheet's own × is the only one (the user's call).
struct TaskNameCanvas: View {
    @Binding var text: String
    var focusOnAppear: Bool
    @State private var focused = false
    @Environment(\.scrollFormToTop) private var scrollFormToTop
    @Environment(\.formTopFieldFocused) private var formTopFieldFocused

    var body: some View {
        HStack(spacing: 8) {
            // The task's name is in SF Pro (the system font), 20pt bold, on
            // New task and Edit task alike (the user's call, 2026-11-05).
            CanvasTextField(text: $text, focused: $focused, placeholder: "Add a task")
                .frame(height: 30)
        }
        .frame(minHeight: 44)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .onAppear {
            guard focusOnAppear else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            formTopFieldFocused(isFocused)
            if isFocused { scrollFormToTop() }
        }
    }
}

/// The big task name: the app's font, slightly tightened, the same while typing
/// as after.
private struct CanvasTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder: String

    private static let font = UIFont.systemFont(ofSize: 20, weight: .bold)
    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor(Neutral.ink)]
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.defaultTextAttributes = Self.attributes
        field.typingAttributes = Self.attributes
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .font: Self.font, .foregroundColor: UIColor(Neutral.border),
        ])
        field.tintColor = UIColor(Neutral.ink)
        field.returnKeyType = .done
        field.autocapitalizationType = .sentences
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
        if focused && !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !focused && field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CanvasTextField
        init(_ parent: CanvasTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { if parent.focused { parent.focused = false } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.focused = false
            return true
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
            .background(selected ? FormGreen.accentBg : EColor.card)
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
    /// Open from the start when days are already set (a chore picked from
    /// the Library, a repeating task being edited), so they're seen at once.
    @State private var expanded: Bool

    init(selectedDays: Binding<Set<String>>) {
        _selectedDays = selectedDays
        _expanded = State(initialValue: !selectedDays.wrappedValue.isEmpty)
    }

    private var summary: String {
        if selectedDays.isEmpty { return "Does not repeat" }
        let label = repeatDisplayLabel(weekDayCodes.filter { selectedDays.contains($0) }.joined(separator: ","))
        return label.isEmpty ? "Does not repeat" : label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Repeats").font(FormRow.title).foregroundStyle(FormGreen.title)
                    Text("Pro").font(Typography.font(11, weight: .bold))
                        .foregroundStyle(FormGreen.proText)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(FormGreen.proBg).clipShape(Capsule())
                    Spacer()
                    Text(summary)
                        .font(FormRow.value)
                        .foregroundStyle(EColor.onSurfaceVariant)
                    FormRow.chevron(open: expanded)
                }
                .frame(minHeight: FormRow.height)
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
                .padding(.bottom, 14)
            }
        }
    }
}

/// The three rows under a task's name (Repeats, Require photo, More options)
/// share one look: the same title, value, chevron, height and the same line
/// above each but the first (2026-11-05: they were three sizes before).
enum FormRow {
    static let title = Typography.font(16, weight: .bold)
    static let value = Typography.font(14, weight: .medium)
    static let height: CGFloat = 54

    static func chevron(open: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(EColor.onSurfaceVariant)
            .rotationEffect(.degrees(open ? 90 : 0))
    }

    static var line: some View {
        Rectangle().fill(Neutral.line).frame(height: 1)
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
                    Text("More options").font(FormRow.title).foregroundStyle(FormGreen.title)
                    Spacer()
                    FormRow.chevron(open: open)
                }
                .frame(minHeight: FormRow.height)
                .contentShape(Rectangle())
                .overlay(alignment: .top) { FormRow.line }
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

// New task's tab of the same name: a blank canvas to type on, which child
// (only when not already fixed), Repeats, and under More options a
// deadline time and instructions. The day comes from the caller, and the
// header (the tabs, the close button) is the sheet's.
struct AddTaskFormFields: View {
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
    @Binding var needsPhoto: Bool
    // The day the task lands on.
    var day: Date
    var canSave: Bool
    var onCancel: () -> Void
    var onSave: () -> Void
    var focusName: Bool = false
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    var body: some View {
        // No hold on the swipe: New task closes with a pull down from the top
        // like any sheet, even with something typed (the user's call,
        // 2026-11-05; it used to stop and ask to discard).
        FormShell(title: "", onCancel: onCancel, onSave: onSave, canSave: canSave, saveLabel: saveLabel,
                  hasChanges: false, showsHeader: false) {
            TaskNameCanvas(text: $taskTitle, focusOnAppear: focusName)
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
    /// One app at a time: picking one replaces the last, so nothing picked
    /// earlier can hide off-screen behind a search.
    var single = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var searching: Bool
    /// In a form (the Block an app sheet): searching keeps the field at the
    /// top, so the results show under it instead of the form scrolling down
    /// and cutting the field off under the title. Elsewhere, nothing.
    @Environment(\.scrollFormToTop) private var scrollFormToTop
    @Environment(\.formTopFieldFocused) private var formTopFieldFocused

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

    /// Searching: every match. Otherwise the top three, plus anything
    /// already picked, so an app found by search stays in view once the
    /// search is cleared.
    private var visibleApps: [ApiApp] {
        if isSearching { return filteredApps }
        let top = Array(filteredApps.prefix(topCount))
        return top + catalog.filter { selectedApps.contains($0.id) && !top.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
                TextField("Search apps", text: $query)
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(EColor.onSurface)
                    .focused($searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { searching = true }
            .onChange(of: searching) { _, on in
                formTopFieldFocused(on)
                if on { scrollFormToTop() }
            }

            VStack(spacing: 6) {
                ForEach(visibleApps) { app in
                    targetRow(title: app.name, selected: selectedApps.contains(app.id)) { toggleApp(app) }
                }
                if isSearching, filteredApps.isEmpty {
                    Text("No apps match")
                        .font(Typography.font(13))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
            }
            // The list folds smoothly as the search narrows it.
            .animation(.snappy(duration: 0.22), value: query)
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
        // Picking one ends the search: the keyboard goes, and the lengths
        // under the list come into view.
        searching = false
        withAnimation(.easeOut(duration: 0.12)) {
            if selectedApps.contains(app.id) { selectedApps.remove(app.id) }
            else if single { selectedApps = [app.id] }
            else { selectedApps.insert(app.id) }
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
}

