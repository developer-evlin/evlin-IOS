import SwiftUI

// What Evlin-iOS's actual chat cards look like: mostly plain
// icon+title+body+buttons (PlanArchCardView), or read-only confirm lists
// (BulkActionCard) — there's no searchable app picker in production at all;
// app blocking there goes through Apple's native FamilyActivityPicker
// outside the card system entirely, and "add task" is copy + Approve/Cancel
// with no structured fields. These two are built for real here instead of
// port-for-port, reusing this app's own AddTaskSheet fields.
private enum ChatCardKind {
    // Blocking an app — opened from the "Block an app" suggestion tile, not
    // by the assistant (its tools are tasks and calendar only; see
    // evlin-backend/tool_calls/). One card: which apps, which kind, detail.
    case blockDraft(BlockDraft)
    // Carries the message that triggered it — AddTaskCard reads this to
    // pre-fill Title/Due the same way inferredRepeats already reads typed
    // text for a repeat cadence, so tapping a specific request ("...to
    // clean his room every Saturday morning") hands back a drafted task to
    // confirm/edit rather than a blank form the parent re-types by hand.
    case addTask(draft: TaskDraft)
    // Several tasks from one reply: one compact card with a row each, not a
    // tall card per task.
    case addTasks(drafts: [TaskDraft])
    // Read-only — what's done/pending/overdue for a child today, pulled
    // from the same TaskStore data their profile shows, not a mocked
    // separate figure.
    case reviewCompliance(childId: String, childName: String)
}

private struct ChatMessage: Identifiable {
    let id = UUID()
    var fromUser: Bool
    var text: String
    var card: ChatCardKind? = nil
    // Which assistant said it. Always "chat" now; the server's column
    // also holds "youtube" on threads from the removed YouTube agent.
    var agent: String = "chat"
    // A draft card's state lives here, not in the card's own view: the
    // list rebuilds rows as they scroll back into view, which reset a
    // card's "Created" and offered the same task again.
    var cardDone = false
    // An older draft a newer one replaced, before anything was created
    // from it. Folded to one grey line; tapping it opens the card again.
    var superseded = false
    // What a used card did, as a small card: its icon, what it was, and a
    // grey detail ("YouTube blocked" / "For 1 hour"). Set a moment after
    // the tap; the full card then collapses into it.
    var receipt: ChatReceipt?
}

/// The chat's start screen, in Gemini's manner: a two-line greeting and a few
/// plain suggestions; only their icons carry colour. Each piece falls into place from the
/// top, one after another, when an empty chat appears (a waterfall, quick and
/// without bounce). Tapping a suggestion does what its help-panel row does.
private struct WelcomeMessage: View {
    let childName: String
    let suggestions: [ChatSuggestion]
    var onPick: (ChatSuggestion) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    /// A suggestion's fill and edge: Apple's soft grey with a firm edge by
    /// day, the card charcoal at night, so each reads as a button
    /// (2026-11-19, the user's call: the thin #E3E3E8 edge on the page
    /// was too faint).
    private static let chipFill = Color(light: "F2F2F7", dark: "262A30")
    private static let chipEdge = Color(light: "D1D1D6", dark: "3D424B")
    /// What this chatbot does, as four small buttons.
    private static let order = ["Block an app", "Daily screen time", "Add a task", "Suggest an activity"]
    private var cards: [ChatSuggestion] {
        Self.order.compactMap { t in suggestions.first { $0.title == t } }
    }

    private func cell(_ s: ChatSuggestion) -> some View {
        Button { onPick(s) } label: {
            HStack(spacing: 10) {
                // The icon on a soft disc of its own colour.
                Image(systemName: EIcon.sf(s.icon))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.tint)
                    .frame(width: 30, height: 30)
                    .background(s.tint.opacity(0.14), in: Circle())
                Text(label(s))
                    .font(ChatType.label(16))
                    .foregroundStyle(EColor.onSurface)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 20)
            .frame(height: 48)
            // A soft grey pill with a firm edge and a faint lift
            // (2026-11-19; a plain pill on the page with a thin #E3E3E8
            // edge, 2026-11-15, before, too faint to read as a button).
            .background(Self.chipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Self.chipEdge, lineWidth: 1.25))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1.5)
            .contentShape(Capsule())
        }
        .buttonStyle(PressedSurfaceStyle())
        .accessibilityHint(s.help)
    }

    private func label(_ s: ChatSuggestion) -> String {
        s.title == "Add a task" ? "Manage tasks" : s.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Says plainly what this is: a simple chatbot.
            Text("Just a simple chatbot that helps you block apps, manage screen time, and come up with activity ideas for \(childName) together.")
                .font(ChatType.body())
                .lineSpacing(ChatType.lineSpacing)
                .foregroundStyle(EColor.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Waterfall(index: 0, shown: shown))

            // Small rounded buttons listed down, each only as wide as its label.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(cards.enumerated()), id: \.offset) { i, s in
                    cell(s)
                        .modifier(Waterfall(index: i + 1, shown: shown))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard shown == 0 else { return }
            let total = cards.count + 1
            if reduceMotion { shown = total; return }
            for i in 1...total {
                withAnimation(.spring(duration: 0.45, bounce: 0)) { shown = i }
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }
}

/// One piece of the welcome falling into place: hidden until its turn, then
/// fading in as it drops the last few points.
private struct Waterfall: ViewModifier {
    let index: Int
    let shown: Int

    func body(content: Content) -> some View {
        let on = index < shown
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : -10)
    }
}

/// The small card a used card collapses into.
/// Calls `onGrow` when the view gets taller after it first appears (a card
/// opened up by a tap), not when it first lays out. The two-value form of
/// onGeometryChange needs iOS 18; this one works back to 17.
private struct GrowthWatcher: ViewModifier {
    var onGrow: () -> Void
    @State private var last: CGFloat = 0

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if last > 0, height > last + 8 { onGrow() }
            last = height
        }
    }
}

private struct ChatReceipt {
    enum Icon {
        case app(String)               // the app's own icon, by name
        case symbol(String, Color)     // the action's icon, in its tile colour
    }
    var icon: Icon
    var title: String
    var detail: String
}

// A stable id the ScrollViewReader can always target, regardless of how
// many messages exist or whether the typing indicator is showing.
private let bottomAnchorID = "chat-bottom-anchor"

// Feeds a GeometryReader probe pinned to the top of the scrolled content up
// to the chrome-hiding logic below — see `chatScrollSpace` / `chromeHidden`.
private struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private let chatScrollSpace = "chatScrollSpace"

// Where the bottom anchor and the composer's top edge sit on screen, so the
// transcript knows whether the parent is reading the newest line (follow the
// reply as it grows) or has scrolled up (leave them alone). The anchor's
// default is "far below": once it's scrolled out of the LazyVStack it isn't
// built at all, which is exactly "not at the bottom".
private struct ChatBottomAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ChatViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ComposerTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private final class ChatEdges {
    var bottomAnchorY: CGFloat = .infinity
    var composerTopY: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

// Asks the ScrollViewReader (only reachable inside body) to scroll. A
// counter, so asking twice in a row still registers.
private struct ScrollRequest: Equatable {
    enum Target: Equatable {
        /// The end of the conversation, unconditionally (opening a thread,
        /// the jump-to-latest button).
        case bottom
        /// Keep the newest line above the composer, but only if it has
        /// gone behind it and the parent hasn't scrolled away.
        case follow
        /// A reply's card landed partly behind the composer: lift it just
        /// enough to show it whole. Only if the parent hasn't scrolled since
        /// sending, and never when it's already in view.
        case reveal
    }
    var count = 0
    var target = Target.follow
    var animated = true
}

// Positions inside the scrolled content itself, which don't move when the
// parent scrolls: the top of the newest message the parent sent, and the
// end of the conversation. Their difference is how tall the latest
// exchange is. -1 means "not built right now" (the LazyVStack drops rows
// far offscreen), and is ignored rather than stored.
private struct LastUserTopKey: PreferenceKey {
    static var defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next >= 0 { value = next }
    }
}
private struct ContentEndKey: PreferenceKey {
    static var defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next >= 0 { value = next }
    }
}
private let chatContentSpace = "chatContentSpace"

// Measures the compose pill's own rendered height, live, so its corner
// radius can be derived from actual content rather than guessed from
// line count — see composerCornerRadius.
private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Bubbles are capped so a long unbroken token (a URL, a hash, code with no
// spaces) wraps inside the bubble instead of forcing the whole HStack wider
// than the screen. `fixedSize(horizontal:false,...)` is the actual fix —
// without it SwiftUI's Text can request its ideal single-line width even
// inside a maxWidth frame, which is the classic cause of chat rows
// overflowing horizontally.
// Shared by the chat bubbles and every card that sits inline with
// them (AddTaskCard here, AddEventCard in its own file), so they all
// line up at the same width.
let bubbleMaxWidth: CGFloat = 300

// Renders a message body: ```-fenced code blocks split into their own
// monospaced, horizontally-scrollable strip so a long code line scrolls
// sideways within its own box instead of stretching the row wide, and
// everything else run through a small line-based block parser — headings
// (#/##) and bullet lists (-/*) get their own treatment, plain lines are
// paragraphs, and every line gets inline **bold** via
// AttributedString(markdown:). Paragraph/bullet text sets no font of its
// own, so it inherits whatever the caller applies to MessageContent
// itself (the user bubble's tighter style, or the assistant's full-width
// body type) — headings always render larger regardless, since they need
// to read as structurally different no matter the body size in use.
/// The conversation's type: Google Sans Flex, the open-source (SIL OFL)
/// release of the Google Sans family Gemini uses. Its optical-size axis is set
/// to the point size, so small text gets the open Text shapes and large text
/// the tighter Display shapes, as Gemini does. Regular for reading; medium and
/// semibold where something should stand out. The rest of the app keeps
/// Plus Jakarta Sans.
enum ChatType {
    static let size: CGFloat = 17
    static let lineSpacing: CGFloat = 5
    // Heavier than the font's 400 everywhere, as Google tunes Gemini for
    // phone screens: a solid reading weight, and each step up a notch more,
    // so everything reads firm while titles still lead.
    static func body() -> Font { font(size, weight: 460) }
    /// Headings inside replies.
    static func heading(_ size: CGFloat = 18) -> Font { font(size, weight: 680) }
    /// The greeting.
    static func title(_ size: CGFloat) -> Font { font(size, weight: 620) }
    /// Card and receipt titles.
    static func strong(_ size: CGFloat) -> Font { font(size, weight: 680) }
    /// Labels: chips, buttons, secondary lines in cards.
    static func label(_ size: CGFloat) -> Font { font(size, weight: 540) }
    /// Secondary text with enough contrast to read at a glance (about 5:1 on
    /// white), rather than the app's pale grey.
    static let secondary = Color(hex: "5E6A62")
    static var font18: Font { font(18, weight: 460) }

    /// The font file ships in the asset catalog (GoogleSansFlex data set,
    /// licence beside it) and is registered once at launch.
    static func registerFont() {
        guard let data = NSDataAsset(name: "GoogleSansFlex")?.data,
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)
    }

    private static func font(_ size: CGFloat, weight: CGFloat) -> Font {
        let axes: [NSNumber: CGFloat] = [
            0x7767_6874: weight,                    // wght
            0x6F70_737A: min(max(size, 6), 144),    // opsz
        ]
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Google Sans Flex",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes,
        ])
        let ui = UIFont(descriptor: descriptor, size: size)
        // Falls back to the system face if the font didn't register.
        return ui.familyName == "Google Sans Flex" ? Font(ui) : .system(size: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
    }
}

private struct MessageContent: View {
    var text: String

    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    EmptyView()
                } else if i % 2 == 1 {
                    codeBlock(trimmed)
                } else {
                    markdownLines(trimmed)
                }
            }
        }
    }

    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func markdownLines(_ block: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(block.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 4)
                } else if line.hasPrefix("## ") {
                    inline(String(line.dropFirst(3))).font(ChatType.heading(18)).padding(.top, 4)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2))).font(ChatType.heading(21)).padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(EColor.onSurfaceVariant).frame(width: 4, height: 4).padding(.top, 11)
                        inline(String(line.dropFirst(2)))
                    }
                } else {
                    inline(line)
                }
            }
        }
    }

    // lineSpacing lives here, scoped to each line, rather than as a
    // blanket modifier the caller applies to the whole message — SwiftUI
    // counts .lineSpacing() as trailing space after the *last* line too,
    // not just between lines, so applying it once around an entire
    // multi-paragraph reply was inflating the gap after assistant
    // messages specifically (the ones using it) well past the 24pt turn
    // spacing, while the plain user bubble looked normal beside it.
    private func inline(_ s: String) -> some View {
        let t = (try? AttributedString(markdown: s)).map(Text.init) ?? Text(s)
        return t.lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
}

// Three dots that bounce in a staggered loop while a response is pending.
// No card any more — matches the assistant's own messages, which now sit
// plain on the chat background with nothing drawn around them. A soft
// scale+opacity pulse (not the old boxed bounce) reads as "thinking"
// rather than "loading," which is the more modern idiom this kind of
// indicator uses elsewhere now.
private struct TypingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(EColor.primary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1 : 0.5)
                    .opacity(pulse ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.16),
                        value: pulse
                    )
            }
        }
        .frame(height: 28)
        .onAppear { pulse = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evlin is typing")
    }
}

// MARK: - Inline chat cards


// No category picker anymore — a chat-created task doesn't need a manual
// classification step. And no manual repeat picker either: rather than
// stopping to ask "how often?" the way the Settings-side AddTaskSheet's
// RepeatPicker does, this reads the parent's own words for frequency cues
// (see inferredRepeats below) and shows what it inferred instead of asking
// — a live, visible "reasoning" readout rather than a form field to fill
// in, matching the "AI" framing of doing this from chat in the first
// place.
//
// Fields start pre-filled from whatever the parent actually asked
// (initialPrompt), not blank — the same "read the parent's own words"
// spirit inferredRepeats already applies to frequency, just applied to
// Title/Due too, so this reads as the AI having drafted a task rather than
// handing back an empty form to fill in by hand.
private struct AddTaskCard: View {
    var draft: TaskDraft
    var onCreate: (_ draft: TaskDraft) -> Void

    @State private var title: String
    @State private var whatToDo: String
    @State private var dueDate: Date
    @State private var dueTime: Date
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var repeatDays: Set<String>
    @State private var submitted = false

    /// `done`: already created; see ChatMessage.cardDone.
    /// What the button says: "Create task" in chat, "Save" when it edits
    /// one row of a several-task card.
    var submitLabel = "Create task"

    init(draft: TaskDraft, done: Bool = false, submitLabel: String = "Create task",
         onCreate: @escaping (_ draft: TaskDraft) -> Void) {
        self.draft = draft
        self.onCreate = onCreate
        self.submitLabel = submitLabel
        _submitted = State(initialValue: done)
        _title = State(initialValue: draft.title)
        _whatToDo = State(initialValue: draft.instructions)
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _hasDueTime = State(initialValue: draft.dueMinutes != nil)
        _dueDate = State(initialValue: draft.dueDate ?? Date())
        let minutes = draft.dueMinutes ?? (18 * 60)
        _dueTime = State(initialValue: Calendar.current.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date())
        _repeatDays = State(initialValue: Self.days(from: draft.recurrence))
    }

    /// The card speaks the recurrence vocabulary the API uses; RepeatPicker
    /// speaks weekday sets. "daily" is all seven.
    private static func days(from recurrence: String) -> Set<String> {
        let r = recurrence.trimmingCharacters(in: .whitespaces).lowercased()
        if r == "daily" { return Set(weekDayCodes) }
        if r == "none" || r.isEmpty { return [] }
        return Set(r.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            .intersection(weekDayCodes)
    }

    private var recurrence: String {
        if repeatDays.isEmpty { return "none" }
        return weekDayCodes.filter { repeatDays.contains($0) }.joined(separator: ",")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var canCreate: Bool { !trimmedTitle.isEmpty && !submitted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Title is the one thing that must be there, so it gets the
            // prominence rather than sitting in an identical box to the
            // optional fields.
            TextField("Task name", text: $title)
                .font(ChatType.label(17))
                .textFieldStyle(.plain)
                .submitLabel(.done)

            Divider()

            // Optional fields read as optional: a row you add, not an empty
            // box implying something is missing.
            optionalRow(isOn: $hasDueDate, icon: "calendar", label: "Date") {
                DatePicker("", selection: $dueDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            optionalRow(isOn: $hasDueTime, icon: "clock", label: "Deadline") {
                DatePicker("", selection: $dueTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            RepeatPicker(selectedDays: $repeatDays)

            if !whatToDo.isEmpty || submitted {
                Divider()
                TextField("Notes", text: $whatToDo, axis: .vertical)
                    .font(ChatType.label(14))
                    .lineLimit(1...4)
            } else {
                Button { whatToDo = " " } label: {
                    Label("Add notes", systemImage: "text.alignleft")
                        .font(ChatType.label(14))
                        .foregroundStyle(EColor.primary)
                }
                .buttonStyle(PressedFadeStyle())
                .frame(minHeight: 44, alignment: .leading)
            }

            Button {
                submitted = true
                onCreate(currentDraft)
            } label: {
                Text(submitLabel)
                    .font(ChatType.label(15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canCreate ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressedSurfaceStyle())
            .disabled(!canCreate)
            .accessibilityHint(trimmedTitle.isEmpty ? "Add a task name first" : "")
        }
        .padding(16)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EColor.outlineVariant))
        .disabled(submitted)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 15)).foregroundStyle(EColor.primary)
            Text("Add a task").font(ChatType.strong(15)).foregroundStyle(EColor.onSurface)
            Spacer()
            if submitted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.greenDeep)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// A field that isn't required: off, it's a single "add" row; on, it
    /// shows the real control with a way back out.
    @ViewBuilder
    private func optionalRow<Content: View>(
        isOn: Binding<Bool>, icon: String, label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isOn.wrappedValue {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(width: 20)
                Text(label).font(ChatType.label(14)).foregroundStyle(EColor.onSurface)
                Spacer()
                content()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
                .buttonStyle(PressedFadeStyle())
                .accessibilityLabel("Remove \(label.lowercased())")
            }
            .frame(minHeight: 44)
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue = true }
            } label: {
                Label(label, systemImage: icon)
                    .font(ChatType.label(14))
                    .foregroundStyle(EColor.primary)
            }
            .buttonStyle(PressedFadeStyle())
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    private var currentDraft: TaskDraft {
        var out = draft
        out.title = trimmedTitle
        out.instructions = whatToDo.trimmingCharacters(in: .whitespaces)
        out.dueDate = hasDueDate ? dueDate : nil
        if hasDueTime {
            let c = Calendar.current.dateComponents([.hour, .minute], from: dueTime)
            out.dueMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        } else {
            out.dueMinutes = nil
        }
        out.recurrence = recurrence
        return out
    }
}

/// Several tasks from one reply, as one compact card: a row each (the title,
/// and when in short grey words), a tick to leave one out, a tap to change
/// one in the full task card, and one button for all of them. A single task
/// keeps AddTaskCard; one tall card per task made three tasks a long scroll.
private struct TaskBatchCard: View {
    var done: Bool
    var onCreate: ([TaskDraft]) -> Void

    @State private var drafts: [TaskDraft]
    @State private var included: [Bool]
    @State private var submitted: Bool
    @State private var editing: Row?

    private struct Row: Identifiable { let id: Int }

    init(drafts: [TaskDraft], done: Bool = false, onCreate: @escaping ([TaskDraft]) -> Void) {
        self.done = done
        self.onCreate = onCreate
        _drafts = State(initialValue: drafts)
        _included = State(initialValue: drafts.map { _ in true })
        _submitted = State(initialValue: done)
    }

    private var chosen: [TaskDraft] { drafts.indices.filter { included[$0] }.map { drafts[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 15)).foregroundStyle(EColor.primary)
                Text("\(drafts.count) tasks").font(ChatType.strong(15)).foregroundStyle(EColor.onSurface)
                Spacer()
                if submitted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.greenDeep)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            VStack(spacing: 0) {
                ForEach(drafts.indices, id: \.self) { i in
                    if i > 0 { Divider() }
                    row(i)
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { submitted = true }
                onCreate(chosen)
            } label: {
                Text(submitted ? "Created" : chosen.count == 1 ? "Create 1 task" : "Create \(chosen.count) tasks")
                    .font(ChatType.label(15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(!chosen.isEmpty || submitted ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressedSurfaceStyle())
            .disabled(chosen.isEmpty || submitted)
        }
        .padding(16)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EColor.outlineVariant))
        .sheet(item: $editing) { row in
            NavigationStack {
                ScrollView {
                    AddTaskCard(draft: drafts[row.id], submitLabel: "Save") { changed in
                        drafts[row.id] = changed
                        editing = nil
                    }
                    .padding(16)
                }
                .navigationTitle("Change task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } } }
            }
            .presentationDetents([.large])
        }
    }

    private func row(_ i: Int) -> some View {
        let on = included[i]
        return HStack(spacing: 12) {
            Button { editing = Row(id: i) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(drafts[i].title)
                        .font(ChatType.label(15))
                        .foregroundStyle(on ? EColor.onSurface : EColor.onSurfaceVariant)
                        .lineLimit(2)
                    Text(Self.when(drafts[i]))
                        .font(ChatType.label(13))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressedFadeStyle())
            .disabled(submitted)
            .accessibilityHint("Opens this task to change it")

            Button { included[i].toggle() } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? Brand.greenDeep : EColor.outlineVariant)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submitted)
            .sensoryFeedback(.selection, trigger: on)
            .accessibilityLabel(on ? "Included" : "Left out")
        }
        .padding(.vertical, 6)
    }

    /// "Mon, Wed, Fri · 4:00 PM", "Tomorrow", "Sat 24 Oct · 10:00 AM".
    static func when(_ d: TaskDraft) -> String {
        var parts: [String] = []
        if d.recurrence != "none", !d.recurrence.isEmpty {
            parts.append(d.recurrence == "daily" ? "Every day" : repeatDisplayLabel(d.recurrence))
        } else if let date = d.dueDate {
            let cal = Calendar.current
            if cal.isDateInToday(date) { parts.append("Today") }
            else if cal.isDateInTomorrow(date) { parts.append("Tomorrow") }
            else {
                let f = DateFormatter(); f.dateFormat = "EEE d MMM"
                parts.append(f.string(from: date))
            }
        }
        if let m = d.dueMinutes {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            let t = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            parts.append(f.string(from: t))
        }
        return parts.isEmpty ? "No day set" : parts.joined(separator: " · ")
    }
}

// AI "reads" the child's real task list and reports what's done vs. still
// outstanding — replaces the old one-tap "lock this app" suggestion with a
// status readout, matching the parent's actual ask (what did they finish,
// not what should I block).
private struct ReviewComplianceCard: View {
    let childId: String
    let childName: String

    // Today's tasks only, by the same rule as the profile's Today's Tasks
    // list. This counted every task on every day, so it could read "26
    // pending, on track today" while today's list was empty.
    private var tasks: [ChildTask] { TaskStore.tasks(for: childId).filter(\.isDueToday) }
    private var done: [ChildTask] { tasks.filter { $0.state == .done } }
    private var waiting: [ChildTask] { tasks.filter { $0.state == .review } }
    private var overdue: [ChildTask] { tasks.filter { $0.state == .overdue } }
    private var notStarted: Int { tasks.count - done.count - waiting.count - overdue.count }
    private var fraction: Double { tasks.isEmpty ? 0 : Double(done.count) / Double(tasks.count) }

    // What's left, in the order a parent would act on it: their own
    // reviews first, then what's late, then what hasn't been started.
    private var breakdown: String {
        if tasks.isEmpty { return "Nothing scheduled for today." }
        if done.count == tasks.count { return "Everything's done for today." }
        var parts: [String] = []
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting for your review") }
        if !overdue.isEmpty { parts.append("\(overdue.count) overdue") }
        if notStarted > 0 { parts.append("\(notStarted) not started") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(childName) today")
                .font(ChatType.label(13))
                .foregroundStyle(EColor.onSurfaceVariant)

            // The headline is the real count, not three equal-weight boxes.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(done.count) of \(tasks.count)")
                    .font(ChatType.label(24))
                    .foregroundStyle(EColor.onSurface)
                Text(tasks.count == 1 ? "task done" : "tasks done")
                    .font(ChatType.label(14))
                    .foregroundStyle(EColor.onSurfaceVariant)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(EColor.surfaceContainerHigh)
                    Capsule()
                        .fill(Brand.greenDeep)
                        .frame(width: max(fraction > 0 ? 8 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text(breakdown)
                .font(ChatType.label(13))
                .foregroundStyle(overdue.isEmpty ? EColor.onSurfaceVariant : EColor.danger)

            if !overdue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(overdue) { task in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(EColor.danger)
                            Text(task.title)
                                .font(ChatType.label(13))
                                .foregroundStyle(EColor.onSurface)
                            Spacer()
                            if let due = task.dueLabel {
                                Text(due)
                                    .font(ChatType.label(11))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                    }
                }
                .padding(10)
                .background(EColor.danger.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
        .accessibilityElement(children: .combine)
    }
}

private struct Capability: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var sub: String
    var tint: Color
}

// What the assistant can actually do — its tools are in
// evlin-backend/tool_calls/. Keep this list to what's true: it drafts, the
// parent confirms, and nothing here should promise more.
// Tasks and app blocks are covered by the tiles' own entries in the help
// panel; these are the two things no tile shows.
private let capabilities: [Capability] = [
    Capability(icon: "questionmark.bubble", title: "Asks instead of guessing", sub: "One short question when a request is unclear.", tint: Color(hex: "7C5CD9")),
    Capability(icon: "brain", title: "Remembers what matters", sub: "Routines and what worked carry over between chats.", tint: Color(hex: "D9468F")),
]

// Grid prompt tiles for the empty-conversation state — the Gemini/ChatGPT
// "here's what you can ask" pattern, a mix of a ready-to-run app action and
// a few broader capability prompts so the grid reads as illustrative rather
// than a single-category shortcut list.
private struct ChatSuggestion: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var prompt: String
    var card: ChatCardKind? = nil
    // Only read when `card` is nil — a card-carrying tile's reply comes from
    // its own intro text in sendSuggestion instead (see .blockDraft/.addTask/
    // .reviewCompliance there). Lets a plain-text suggestion (no structured
    // follow-up) still land a reply tailored to what it actually asked,
    // rather than every one of them collapsing onto the same generic
    // "Got it — I'll take care of that." line.
    var reply: String? = nil
    // What the tile does, for the help panel. Keep it to what tapping it
    // really does today.
    var help: String = ""
    // The server asks this tile's first question itself, without the model
    // (chat.py SHORTCUT_QUESTIONS): instant instead of 4-5 seconds.
    var shortcut: String? = nil
    // The tile's own icon color, on a soft circle of the same hue. Each
    // tile gets one so the grid reads at a glance, not as six green icons.
    var tint: Color = Brand.greenDeep
}

// The name of the child this chat is about, for the tiles' messages. They
// are sent as the parent's own words, so they name the child the way a
// parent would ("How is Wse doing…"), never "your child" and never a
// guessed pronoun.
@MainActor
private var activeChildName: String {
    let id = SessionManager.shared.activeChildId
    return FamilyStore.children.first { $0.id == id }?.name ?? "my child"
}

@MainActor
private var welcomeSuggestions: [ChatSuggestion] {[
    ChatSuggestion(icon: "sf:checkmark", title: "Review your child's progress", prompt: "How is \(activeChildName) doing with today's tasks?", card: .reviewCompliance(childId: SessionManager.shared.activeChildId ?? "", childName: activeChildName),
                   help: "Today's tasks: done, waiting for you, or not started.",
                   tint: Brand.greenDeep),
    // Deliberately open. This used to send a fully-specified sentence
    // ("clean his room every Saturday morning") and pre-fill the card with
    // it, so tapping the tile looked like the assistant inventing a task out
    // of nowhere. Now it asks what the task is.
    ChatSuggestion(icon: "sf:checklist", title: "Add a task",
                   prompt: "I'd like to add a task",
                   help: "Say what and when. Nothing's created until you tap Create.",
                   shortcut: "add_task",
                   tint: Color(hex: "3B6FD8")),
    // Asks which app first (instantly, chat.py SHORTCUT_QUESTIONS); the
    // agent then drafts the block card from the answer.
    ChatSuggestion(icon: "sf:nosign", title: "Block an app", prompt: "Block an app for \(activeChildName)",
                   help: "Say which app. Evlin suggests how long; change it before you block.",
                   shortcut: "block_app",
                   tint: Color(hex: "E0574F")),
    ChatSuggestion(
        icon: "sf:lightbulb.fill", title: "Suggest an activity",
        prompt: "Suggest something \(activeChildName) can do instead of screen time",
        // No canned reply: this used to answer every child with the same
        // "LEGO build or a walk" line. The model suggests real habits from
        // the child's age and what they've completed (chat.py), as cards.
        help: "Real habits that fit their age, ready to add.",
        shortcut: "suggest_activity",
        tint: Color(hex: "D49A06")
    ),
    // Answered by the chatbot from today's limit and what's been earned.
    ChatSuggestion(icon: "sf:hourglass", title: "Daily screen time",
                   prompt: "How much screen time does \(activeChildName) have today?",
                   help: "Today's limit, and what tasks have added to it.",
                   tint: Color(light: "1F6390", dark: "6AA9D6")),
]}

struct ScreenChat: View {
    /// The send button with nothing to send: a circle a step deeper than the
    /// message bar, so it reads as a button (2026-11-14).
    private static let sendIdle = Color(light: "E5E5EA", dark: "30343B")
    /// The message bar's edge: none by day (its shadow sets it apart), fine
    /// at night.
    private static let composerEdge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: "353A42")) : .clear })
    @Environment(SessionManager.self) private var session

    // No canned "I'm Evlin" bubble seeded in — the empty state's WelcomeMessage
    // already carries that greeting, so the transcript itself only ever
    // holds real exchanges the user actually sent/received.
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    // Selection ticks: a tile tapped, an old draft unfolded.
    @State private var tickCount = 0
    // The app's "newly added" tap, once per card used (task, block).
    @State private var addedTick = 0
    // A light tap for each new chat, as for each send.
    @State private var newChatTick = 0
    // Block an app, as Profile's sheet (see sendSuggestion).
    @State private var showBlockSheet = false
    // Set when the parent drags the conversation after sending, so a card
    // landing later doesn't pull the view away from what they're reading.
    @State private var userScrolledSinceSend = false
    @State private var isSending = false
    // The one in-flight "assistant is replying" unit of work, whatever
    // shape it currently is (a delay before a card appends, or a streaming
    // reply writing itself in word by word) — see beginResponse. Cancelled
    // before anything new starts, so two responses can never race each
    // other into `messages` at once.
    @State private var responseTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var showHistory = false
    // Tracks which history thread is currently loaded into `messages` so the
    // sidebar can highlight it — the "active state" pill from Gemini/ChatGPT's
    // history list. Cleared on "New chat".
    // The thread currently in the transcript. nil means "New chat" — no
    // row exists server-side until the first message is sent, so a stray
    // tap on New chat doesn't leave an empty thread in the list.
    @State private var activeConversationID: String?
    @State private var conversations: [ApiChatConversation] = []
    @FocusState private var inputFocused: Bool
    // Instagram-style collapse: scrolling down hides the nav bar + tab bar so
    // the transcript gets the full screen, matching a standalone chat app's
    // scale (see the "make chat bigger, like Gemini" ask) rather than the
    // cramped feel of a fifth of the screen permanently eaten by chrome.
    // Scrolling back up (or landing near the top) restores it.
    @State private var chromeHidden = false
    @State private var lastChatScrollOffset: CGFloat = 0
    // Live-measured height of the compose pill — drives its corner radius
    // (see composerCornerRadius) so it eases from a full pill down to a
    // fixed radius as the text wraps, instead of scaling into a stretched
    // oval or snapping to a flat rect.
    @State private var composerHeight: CGFloat = 0
    // Coalesces "scroll to bottom" requests — messages.count and isSending
    // often change in the same tick (see beginResponse), which used to
    // fire two competing animated scrolls at once. Cancelling and
    // deferring by one tick also gives a newly-inserted tall row (a card
    // reply) time to finish laying out before the anchor position is
    // computed, instead of landing short and leaving it half-hidden
    // behind the composer.
    @State private var scrollTask: Task<Void, Never>?
    @State private var scrollRequest = ScrollRequest()
    // Whether new content should pull the transcript down with it. True
    // while the parent is at the bottom; scrolling up turns it off so a
    // reply still writing itself in doesn't drag them back mid-read, and
    // scrolling back down turns it on again.
    // Whether the parent is near the end of the conversation (within 100pt
    // of it), judged whenever they scroll. Only then does a growing reply
    // pull the view along; scrolled further up, they're left where they are
    // and the jump button appears instead.
    @State private var followsBottom = true
    // A reply is writing itself in (after the typing dots).
    @State private var isStreaming = false
    // The move that brings the parent's new message to the top. Separate
    // from scrollTask so the typing dots appearing in the same tick (a
    // follow request) can't cancel it.
    @State private var pinTask: Task<Void, Never>?
    @State private var pinGeneration = 0
    // The visible height the space under the latest exchange is sized
    // against. Copied from edges.viewportHeight only when the conversation
    // itself changes (a message, the reply growing), never while the
    // keyboard or the bars move: resizing the content mid-gesture made the
    // scroll view fight the drag that dismisses the keyboard, and the text
    // got stuck partway.
    @State private var tailViewport: CGFloat = 0
    @State private var lastUserTop: CGFloat = -1
    @State private var contentEnd: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Bumped on every send, for the send button's haptic.
    @State private var sendCount = 0
    // Read only when judging followsBottom, never drawn, so they live in a
    // holder SwiftUI doesn't watch. As @State, every write re-rendered the
    // transcript, which re-reported the anchor in the same frame ("Bound
    // preference ChatBottomAnchorKey tried to update multiple times per
    // frame") on every frame of a scroll.
    @State private var edges = ChatEdges()

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                  VStack(spacing: 0) {
                    // LazyVStack, not VStack: this list can grow long over a
                    // real conversation, and only rows on/near screen should
                    // be built.
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if messages.isEmpty {
                            // Empty-conversation state: Evlin's greeting, written
                            // in word by word, with what it can do as tappable
                            // phrases — replaced by the transcript once a real
                            // exchange starts.
                            WelcomeMessage(childName: activeChildName, suggestions: welcomeSuggestions) { s in
                                sendSuggestion(s)
                            }
                                .padding(.top, 8)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                ))
                        }

                        // Rows go straight into the LazyVStack. They used to
                        // sit in a plain VStack inside it, which made the
                        // whole conversation one row: every message was
                        // built and laid out up front, however long it got.
                        ForEach(messages) { m in
                            if m.fromUser {
                                HStack {
                                    Spacer(minLength: 40)
                                    // Same 15pt as the replies, so the
                                    // two sides read at one size; an
                                    // 18pt continuous corner keeps a
                                    // one-liner a bubble, not a pill.
                                    MessageContent(text: m.text)
                                        .font(ChatType.body())
                                        .lineSpacing(ChatType.lineSpacing - 2)
                                        .foregroundStyle(EColor.onSurface)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(EColor.surfaceContainerHigh)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        // The cap goes outside the fill: a
                                        // maxWidth frame inside it grew every
                                        // bubble to the full 300pt, so a
                                        // two-word message was a wide bar.
                                        .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
                                        .contextMenu { copyButton(m.text) }
                                }
                                .background {
                                    if m.id == lastUserMessageID {
                                        GeometryReader { geo in
                                            Color.clear.preference(key: LastUserTopKey.self, value: geo.frame(in: .named(chatContentSpace)).minY)
                                        }
                                    }
                                }
                                .id(m.id)
                                .transition(messageTransition(fromUser: true))
                            } else {
                                // The reply is plain text on the background;
                                // only the parent's side is a bubble, which is
                                // what tells the two apart. A card sits under
                                // the intro line at its own width.
                                if m.superseded, let card = m.card {
                                    Button {
                                        tickCount += 1
                                        unfold(m.id)
                                    } label: {
                                        Text("Earlier draft: \(draftTitle(card)). Show")
                                            .font(ChatType.label(13))
                                            .foregroundStyle(EColor.onSurfaceVariant)
                                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressedFadeStyle())
                                    .accessibilityHint("Shows the earlier draft again")
                                    .id(m.id)
                                } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    // Empty while a reply is about to write
                                    // itself in; nothing to show until a word.
                                    if !m.text.isEmpty {
                                        Group {
                                            if m.card != nil {
                                                Text(m.text)
                                                    .font(ChatType.body())
                                                    .lineSpacing(ChatType.lineSpacing)
                                                    .foregroundStyle(EColor.onSurface)
                                            } else {
                                                // No animation on the text: each
                                                // new word just lands. Animating it
                                                // animated the row's height on every
                                                // word of every reply.
                                                MessageContent(text: m.text)
                                                    .font(ChatType.body())
                                                    .lineSpacing(ChatType.lineSpacing)
                                                    .foregroundStyle(EColor.onSurface)
                                            }
                                        }
                                        .contextMenu { copyButton(m.text) }
                                    }
                                    cardArea(for: m)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // A second card from the same reply sits closer
                                // to the first than a new turn does.
                                .padding(.top, continuesReply(m) ? -12 : 0)
                                .id(m.id)
                                .transition(messageTransition(fromUser: false))
                                }
                            }
                        }

                        if isSending {
                            TypingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("typing")
                                .transition(.opacity)
                        }

                        // Zero-height anchor scrollTo always targets, so
                        // "scroll to newest" means the same thing whether
                        // the last row is a real message or the typing dots.
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: ChatBottomAnchorKey.self, value: geo.frame(in: .global).maxY)
                                        .preference(key: ContentEndKey.self, value: geo.frame(in: .named(chatContentSpace)).maxY)
                                }
                            )
                    }
                    .coordinateSpace(name: chatContentSpace)
                    .padding(.horizontal, 20)
                    // None on top: the navigation bar above is already tall,
                    // and padding here pushed the start screen's question
                    // and tiles further down than they needed to be.
                    .padding(.bottom, 12)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: messages.count)
                    // A `.background` on the LazyVStack itself, not a row
                    // inside it — a row at the top would get pruned once
                    // scrolled far enough offscreen in a long conversation,
                    // silently freezing the chrome-hide tracking; a modifier
                    // on the container isn't subject to that lazy culling.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ChatScrollOffsetKey.self, value: geo.frame(in: .named(chatScrollSpace)).minY)
                        }
                    )

                    // Room under the latest exchange, so the parent's new
                    // message can sit at the top of the screen with the reply
                    // writing in below it (the ChatGPT/Claude/Gemini layout).
                    // It shrinks as the reply grows and is gone once the
                    // exchange fills the screen. Outside the LazyVStack, so
                    // it never moves anything the measurements depend on.
                    Color.clear.frame(height: tailSpace)
                  }
                  // Taps on empty space close the keyboard. This replaced a
                  // tap watcher on the whole list that also fired under every
                  // tap on a card, so a card's text field lost focus the
                  // moment it got it, and its date pickers closed at once.
                  .background(
                      Color.clear
                          .contentShape(Rectangle())
                          .onTapGesture { endEditing() }
                  )
                }
                .coordinateSpace(name: chatScrollSpace)
                // The visible height between the nav bar and the composer:
                // the scroll view's frame less its safe areas, measured as if
                // the keyboard weren't up. The keyboard only covers the empty
                // space under the exchange; it shouldn't resize it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChatViewportHeightKey.self,
                            value: max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
                        )
                    }
                    .ignoresSafeArea(.keyboard)
                )
                .onPreferenceChange(ChatViewportHeightKey.self) { height in
                    edges.viewportHeight = height
                    if tailViewport == 0 { tailViewport = height }
                }
                .onPreferenceChange(LastUserTopKey.self) { top in
                    if top >= 0, top != lastUserTop {
                        lastUserTop = top
                        commitTailViewport()
                    }
                }
                .onPreferenceChange(ContentEndKey.self) { end in
                    if end >= 0, end != contentEnd {
                        contentEnd = end
                        commitTailViewport()
                    }
                }
                // The app's one page colour, as on every other tab.
                .background(EColor.surface)
                .scrollDismissesKeyboard(.interactively)
                // A tile tapped or an earlier draft unfolded: the app's
                // selection tick, once per tap.
                .sensoryFeedback(.selection, trigger: tickCount)
                .sensoryFeedback(.impact(weight: .light), trigger: addedTick)
                // Every send (typed or a suggestion) and every new chat: a light tap.
                .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
                .sensoryFeedback(.impact(weight: .light), trigger: newChatTick)
                .onUserScroll { userScrolledSinceSend = true }
                .onPreferenceChange(ChatBottomAnchorKey.self) {
                    edges.bottomAnchorY = $0
                    // A reply growing past the composer doesn't scroll, so
                    // this is what brings up the jump-to-latest arrow.
                    updateFollowing()
                }
                .onPreferenceChange(ComposerTopKey.self) {
                    edges.composerTopY = $0
                    updateFollowing()
                }
                .onPreferenceChange(ChatScrollOffsetKey.self) { newOffset in
                    // Only a change in scroll position re-judges following;
                    // a reply growing at the bottom leaves the content's top
                    // where it was, so growth alone can't switch it off.
                    if newOffset != lastChatScrollOffset {
                        updateFollowing()
                    }
                    // The keyboard opening/closing shrinks the safe area,
                    // which shifts this same offset enough to cross the
                    // thresholds below on its own — without this guard,
                    // focusing the compose field could toggle the nav/tab
                    // bar's visibility at the exact moment the keyboard is
                    // also animating in, two competing chrome transitions
                    // firing at once. Chrome-hiding is meant to respond to
                    // an actual scroll gesture, not a side effect of typing.
                    guard !inputFocused else {
                        lastChatScrollOffset = newOffset
                        return
                    }
                    let delta = newOffset - lastChatScrollOffset
                    lastChatScrollOffset = newOffset
                    if newOffset > -8 {
                        // Back at the very top of the whole conversation —
                        // always show chrome here regardless of the last
                        // scroll direction, so it can't get stuck hidden.
                        if chromeHidden { withAnimation(.easeOut(duration: 0.22)) { chromeHidden = false } }
                    } else if delta < -10, !chromeHidden {
                        withAnimation(.easeOut(duration: 0.22)) { chromeHidden = true }
                    } else if delta > 10, chromeHidden {
                        withAnimation(.easeOut(duration: 0.22)) { chromeHidden = false }
                    }
                }
                // The input bar lives in the scroll view's bottom safe-area
                // inset rather than a sibling VStack row: this is what keeps
                // it pinned above the keyboard automatically (SwiftUI shrinks
                // the safe area, not the content, when the keyboard opens)
                // instead of the bar getting shoved off-screen or content
                // sliding underneath it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        inputBar
                    }
                    .animation(.easeOut(duration: 0.2), value: inputFocused)
                }
                // The conversation reads from the top. No bottom anchoring:
                // that would hold the end of the content in place as a reply
                // grows, scrolling the parent's message away.
                // Only sending moves the conversation, as in ChatGPT, Gemini
                // and Claude: the parent's message goes to the top and the
                // reply writes in underneath it. Nothing else scrolls on its
                // own — not focusing the field, not the reply arriving or
                // growing, not the typing dots. Each of those used to pull
                // the view down while the parent was reading or typing; past
                // the screen's edge, the jump-to-latest arrow is the way down.
                .onChange(of: messages.count) { _, _ in
                    if messages.last?.fromUser == true {
                        scrollToLatestUserMessage(proxy)
                    }
                }
                .onChange(of: scrollRequest) { _, request in
                    // A just-opened thread needs its first layout pass done
                    // before there's an end to scroll to.
                    // A card needs a moment to lay out at its full height
                    // before there's a real bottom to show.
                    let delay = request.target == .reveal ? 0.3
                        : request.target == .bottom && !request.animated ? 0.1 : 0.03
                    scroll(proxy, to: request.target, animated: request.animated, after: delay)
                }
            }
            // No title: the tab bar already says Chat. The bar stays for the
            // history and help buttons.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        inputFocused = false
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = true }
                    } label: {
                        flatToolbarIcon("sidebar.leading")
                    }
                    .buttonStyle(PressedFadeStyle())
                    .accessibilityLabel("Chat history")
                }
                .flatToolbarBackground()
                ToolbarItem(placement: .topBarTrailing) {
                    // New chat in the top bar, so starting over doesn't mean
                    // opening the history panel first (ChatGPT and Gemini
                    // keep it there too). No ? button: the start screen's
                    // list already says what the chatbot does.
                    Button(action: startNewChat) { flatToolbarIcon("square.and.pencil") }
                        .buttonStyle(PressedFadeStyle())
                        .disabled(messages.isEmpty && activeConversationID == nil)
                        .accessibilityLabel("New chat")
                }
                .flatToolbarBackground()
            }
            // Instagram-style collapse on scroll (see chromeHidden) — hides
            // both this screen's own nav bar and, since a tab's content can
            // declare its own tab-bar visibility independent of the other
            // tabs, ParentRootView's tab bar too, purely from in here.
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar(chromeHidden ? .hidden : .visible, for: .tabBar)
            // The transcript scrolls under the top of the screen. With the
            // bar showing, the system frosts it once content is underneath
            // (and leaves it clear at rest, so the top doesn't read as its
            // own grey band); with the bar hidden, nothing did, and text ran
            // under the clock. The zero-height strip stretches into the
            // status-bar area only.
            .overlay(alignment: .top) {
                if chromeHidden {
                    Rectangle()
                        .fill(.bar)
                        .frame(height: 0)
                        .ignoresSafeArea(edges: .top)
                        .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showBlockSheet) {
            if let id = session.activeChildId {
                AddBlockedAppsSheet(child: FamilyStore.child(id)) { showBlockSheet = false }
            }
        }
        .sheet(isPresented: $showHelp) {
            Group {
            HelpPanel(isBusy: isSending || isStreaming) { suggestion in
                showHelp = false
                // After the sheet has gone, so the message lands on a
                // visible transcript and its move to the top is seen.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    sendSuggestion(suggestion)
                }
            }
        }
            .presentationDragIndicator(.visible)
        }
        // Full-screen history (Gemini's pattern, not a partial-width drawer)
        // — the conversation canvas stays mounted behind it so closing never
        // re-triggers the transcript's own appear animation.
        .overlay {
            if showHistory {
                ChatHistorySidebar(
                    selectedID: activeConversationID,
                    conversations: conversations,
                    onSelect: { conversation in
                        // Cancel first — an in-flight response belongs to
                        // whatever thread was showing when it started, and
                        // has no business appending into a different one.
                        responseTask?.cancel()
                        isSending = false
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = false }
                        Task { await openConversation(conversation.id) }
                    },
                    onNewChat: {
                        startNewChat()
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = false }
                    },
                    onRename: { conversation, title in
                        Task { await renameConversation(conversation, to: title) }
                    },
                    onDelete: { conversation in
                        Task { await deleteConversation(conversation) }
                    },
                    onClose: { withAnimation(.easeOut(duration: 0.22)) { showHistory = false } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
                .transition(.move(edge: .leading))
            }
        }
        // Opens on a new chat, not the last thread: a parent coming back
        // hours later is almost always starting something new, and the old
        // thread's context would steer the reply. Past threads stay one tap
        // away in the sidebar, and what's worth carrying between
        // conversations already does, through the assistant's memory.
        .task {
            await reloadConversations()
            // Demo only: -EvlinChatSay sends one message, to see its reply.
            if let say = DemoMode.chatSay, messages.isEmpty {
                draft = say
                send()
            }
        }
        // Switching to a different bottom tab shouldn't leave the history
        // panel stuck open underneath — TabView keeps this tab's state
        // alive, but the content view still disappears while another tab
        // is frontmost, so this fires exactly on a tab switch (not on the
        // panel's own overlay presentation, which lives above this view).
        .onDisappear {
            showHistory = false
            responseTask?.cancel()
            scrollTask?.cancel()
        }
    }

    // A new message grows out of its own corner: the parent's from the
    // bottom right, by the send button; a reply from the top left, where it
    // starts reading. Only scale and opacity animate, never layout, so the
    // rows around it don't reflow mid-animation. Reduce Motion gets a fade.
    private func messageTransition(fromUser: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9, anchor: fromUser ? .bottomTrailing : .topLeading)
                .combined(with: .opacity),
            removal: .opacity
        )
    }

    // A plain filled circle in place of iOS 26's glass button, which drew a
    // blur and shadow behind each icon.
    private func flatToolbarIcon(_ systemName: String) -> some View {
        chatToolbarIcon(systemName)
    }

    // Empty-conversation grid — the Gemini/ChatGPT "here's what to try"
    // pattern: one short line, then a 2-column grid of ready-to-run
    // prompts. The logo, name and a greeting that repeated the name used
    // to take a third of the screen above the tiles; the nav bar already
    // says where you are, and the ? button covers what Evlin can do.

    // Gemini's proportions, not just its rounded corners: a single-line
    // pill (52pt — 34pt send button + 9pt vertical padding each side) at
    // rest, not a tall rounded rectangle that reads like a textarea
    // waiting for an essay — which was also why the bottom region needed
    // its own background band in the first place. At this height the
    // pill is light enough to float directly on the chat background (no
    // band; see body's safeAreaInset). Spans the same 16pt gutter as the
    // floating tab bar below it so their edges line up — no separate
    // attach affordance eating into that width, since nothing in this
    // chat flow takes a file attachment.
    private var inputBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Gemini-sized: 18pt in full ink, with a placeholder that's
            // readable rather than faint.
            TextField("", text: $draft,
                      prompt: Text("Ask Evlin anything")
                          .foregroundStyle(EColor.onSurface.opacity(0.45)),
                      axis: .vertical)
                .font(ChatType.font18)
                .foregroundStyle(EColor.onSurface)
                // Caps at 4 lines (not 8) — past that it scrolls
                // internally rather than keep growing toward a
                // full-screen textarea.
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)

            if isSending || isStreaming {
                // While a reply is on its way the send button becomes stop,
                // as in every current AI chat: a bad reply can be cut short.
                Button(action: stopReply) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Brand.greenDeep)
                        .clipShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("Stop reply")
                .transition(.scale.combined(with: .opacity))
            } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(canSend ? .white : EColor.onSurface.opacity(0.55))
                    .frame(width: 40, height: 40)
                    // A real filled state either way — quiet grey while
                    // empty, not a near-white circle that reads as broken
                    // rather than disabled; solid Evlin green the moment
                    // there's something to send, animating between the
                    // two rather than snapping.
                    .background(canSend ? Brand.greenDeep : Self.sendIdle)
                    .clipShape(Circle())
                    .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .transition(.scale.combined(with: .opacity))
            }
        }
        // 40pt button + 12pt above and below: a 64pt bar, Gemini's size.
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: ComposerHeightKey.self, value: geo.size.height)
                    .preference(key: ComposerTopKey.self, value: geo.frame(in: .global).minY)
            }
        )
        // A white pill floating on a soft shadow, as in Gemini, instead of
        // an outlined box: the outline read as a form field, not a chat.
        .background(
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                // The page's colour on a soft shadow, no outline and no green
                // while typing (2026-11-15, the user's design: "no green light
                // aura"; a grey fill whose edge turned green while typing,
                // 2026-11-14, before). At night a fine edge, where a shadow
                // doesn't show.
                .fill(EColor.surface)
                .shadow(color: Color.black.opacity(0.09), radius: 16, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                        .strokeBorder(Self.composerEdge, lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.18), value: composerHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
    }

    // Fully rounded at rest (radius = half the single-line height, a true
    // pill — 26pt at the 52pt rest height, true semicircle ends), easing
    // down to a fixed 22pt as the text wraps to more lines — not scaling
    // radius up *with* height, which is what would produce a stretched
    // capsule instead of an ordinary rounded rect once it's grown past
    // one line.
    private var composerCornerRadius: CGFloat {
        let restHeight: CGFloat = 64
        let maxRadius = restHeight / 2
        let minRadius: CGFloat = 26
        let growthRange: CGFloat = 40
        guard composerHeight > restHeight else { return maxRadius }
        let eased = min(1, (composerHeight - restHeight) / growthRange)
        return maxRadius - (maxRadius - minRadius) * eased
    }

    private var lastUserMessageID: UUID? {
        messages.last(where: { $0.fromUser })?.id
    }

    // Empty space under the latest exchange: enough that the parent's
    // newest message can be scrolled to the top of the visible area.
    private var tailSpace: CGFloat {
        guard lastUserMessageID != nil, lastUserTop >= 0, contentEnd >= lastUserTop else { return 0 }
        return max(0, tailViewport - (contentEnd - lastUserTop))
    }

    private func commitTailViewport() {
        let height = edges.viewportHeight
        if height > 0, height != tailViewport { tailViewport = height }
    }

    // Near the end means the newest line is at most 100pt below the
    // composer's top (negative when it's visible above it).
    private func updateFollowing() {
        // The composer's position starts at 0 until it's measured.
        guard edges.composerTopY > 0 else { return }
        let below = edges.bottomAnchorY - edges.composerTopY
        let near = below <= 100
        if near != followsBottom { followsBottom = near }
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: ScrollRequest.Target,
                        animated: Bool, after delay: Double = 0.03) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            // A row inserted this tick hasn't finished laying out (a tall
            // card especially); scrolling now would aim at its old size.
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if target == .reveal {
                guard !userScrolledSinceSend, pinTask == nil, edges.bottomAnchorY > edges.composerTopY else {
                    updateFollowing()
                    return
                }
            }
            if target == .follow {
                // Already above the composer: nothing is hidden, and
                // scrolling would only push the parent's message off the top.
                // Nor while that message is still on its way up.
                guard followsBottom, pinTask == nil, edges.bottomAnchorY > edges.composerTopY else {
                    updateFollowing()
                    return
                }
            }
            let move = { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
            if animated {
                withAnimation(.easeOut(duration: 0.25), move)
            } else {
                move()
            }
            followsBottom = true
        }
    }

    private func scrollToLatestUserMessage(_ proxy: ScrollViewProxy) {
        guard let id = lastUserMessageID else { return }
        scrollTask?.cancel()
        pinTask?.cancel()
        pinGeneration += 1
        let generation = pinGeneration
        pinTask = Task { @MainActor in
            // A cancelled older move finishing late mustn't clear the
            // newer one's handle.
            defer { if pinGeneration == generation { pinTask = nil } }
            // Two layout passes: one to measure the new message, one for
            // the space under it to grow; before that there's no room to
            // bring it to the top.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                proxy.scrollTo(id, anchor: .top)
            }
            followsBottom = true
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    // A reply that writes itself in word by word isn't read out as it goes;
    // VoiceOver gets the whole thing once it's done.
    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    // Stops a reply: the wait for the server, the typing delay, or the
    // word-by-word reveal. What's been revealed so far stays.
    private func stopReply() {
        responseTask?.cancel()
        isSending = false
        isStreaming = false
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(fromUser: true, text: text))
        draft = ""
        sendCount += 1
        // The keyboard goes down on send, as in ChatGPT, Gemini and Claude:
        // writing is finished, and the reply (a card, often) needs the room.
        inputFocused = false
        userScrolledSinceSend = false
        sendToBackend(text)
    }

    // Tapping a WelcomeMessage phrase (or a help panel row) — same flow as send(), just sourced from a
    // preset prompt instead of the draft field. A tile that already knows
    // its own target card (Block an app, Add a task, Review progress) shows
    // it instantly — no ambiguity for the model to resolve, the button
    // already says what it means. Everything else (a plain suggestion, or
    // one of the two prompts with no card — "Set a bedtime rule"/"Update
    // the calendar," which used to fake a canned reply) goes to the real
    // backend exactly like a typed message would.
    private func sendSuggestion(_ suggestion: ChatSuggestion) {
        guard !isSending else { return }
        // Until the server drafts blocks (ServerSupport.chatBlocks), Block an
        // app opens the same sheet as Profile's, which the server takes.
        if suggestion.shortcut == "block_app", !ServerSupport.chatBlocks {
            tickCount += 1
            showBlockSheet = true
            return
        }
        sendCount += 1
        userScrolledSinceSend = false
        messages.append(ChatMessage(fromUser: true, text: suggestion.prompt))
        if case .reviewCompliance = suggestion.card {
            // The model answers this one (it has today's tasks and their
            // status in its prompt), and the card with the real counts
            // comes attached to its reply rather than a canned line.
            sendToBackend(suggestion.prompt, attaching: suggestion.card)
        } else if let card = suggestion.card {
            beginResponse(afterSeconds: 0.6) {
                let intro: String
                switch card {
                // The card below is where the answer goes, so the intro
                // points at it instead of asking a question to type back.
                case .blockDraft: intro = "Pick the app and how long to block it:"
                case .addTask: intro = "I've drafted this from what you asked — check it over and create it:"
                // The tile sends this one to the model instead (see above);
                // kept for the switch to stay exhaustive.
                case .reviewCompliance(_, let childName): intro = "Here's where \(childName) stands today:"
                // Not reachable from a tile — only from a real tool call.
                case .addTasks: intro = ""
                }
                messages.append(ChatMessage(fromUser: false, text: intro, card: card))
            }
        } else if let reply = suggestion.reply {
            respondAfterDelay(with: reply)
        } else {
            sendToBackend(suggestion.prompt, shortcut: suggestion.shortcut)
        }
    }

    // The real backend call — stores the message, grounds the model in
    // this child's actual today's-tasks/rules, and returns either a plain
    // reply or a proposal to open one of the two existing cards (never a
    // direct write; see routers/chat.py). Runs through the same
    // beginResponse-owned Task as every other reply path, so a second
    // message sent mid-flight cancels this one outright instead of racing.
    // `attaching`: a card shown under this reply, whatever the model says —
    // and under the error line if the model can't be reached, since the
    // card's numbers come from the device, not the model.
    private func sendToBackend(_ text: String, attaching attached: ChatCardKind? = nil, shortcut: String? = nil) {
        responseTask?.cancel()
        isSending = true
        let agent = "chat"
        responseTask = Task { @MainActor in
            guard let childId = session.activeChildId else { isSending = false; return }
            do {
                // No active thread means this is a New chat: ask for a fresh
                // one explicitly rather than letting the server append to
                // whatever was most recent.
                let reply = try await APIClient.shared.sendChatMessage(
                    childId: childId, text: text,
                    conversationId: activeConversationID,
                    startNewConversation: activeConversationID == nil,
                    agent: agent,
                    shortcut: shortcut
                )
                guard !Task.isCancelled else { return }
                isSending = false
                // The server creates the thread on the first message, so
                // this is where a New chat gets its id — without it the next
                // message would start yet another one.
                if activeConversationID == nil { activeConversationID = reply.conversationId }
                await reloadConversations()
                if reply.toolCall != nil {
                    foldUnusedDrafts()
                    // Several things asked for at once: one card each, in
                    // the order the parent said them, except tasks, which
                    // share one compact card (groupedTaskDrafts).
                    var replyRows = [ChatMessage(fromUser: false, text: reply.text, card: attached ?? cardFor(reply),
                                                 agent: reply.agent ?? agent)]
                    for extra in reply.extraMessages ?? [] {
                        replyRows.append(ChatMessage(fromUser: false, text: extra.text, card: cardFor(extra),
                                                     agent: extra.agent ?? agent))
                    }
                    messages.append(contentsOf: Self.groupedTaskDrafts(replyRows))
                    // A card is something to act on, so it's shown whole.
                    scrollRequest.count += 1
                    scrollRequest.target = .reveal
                    scrollRequest.animated = true
                } else {
                    messages.append(ChatMessage(fromUser: false, text: "", card: attached, agent: reply.agent ?? agent))
                    guard let id = messages.last?.id else { return }
                    streamIn(reply.text, into: id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                isSending = false
                messages.append(ChatMessage(fromUser: false, text: "Couldn't reach Evlin's AI. \(error.apiUserMessage)", card: attached,
                                            agent: agent))
            }
        }
    }

    // Maps a real tool-call response onto one of the two existing cards —
    // shared between a live reply (sendToBackend) and a reopened thread's
    // rows (openConversation) so both build the exact same card the same way.
    private func cardFor(_ message: ApiChatMessage) -> ChatCardKind? {
        switch message.toolCall {
        case "draft_task":
            // Straight through as structured values. This used to flatten
            // the model's fields into an English sentence that the card then
            // re-parsed with string matching — which failed on every real
            // tool call, so the card always arrived empty.
            return .addTask(draft: TaskDraft(toolArgs: message.toolArgs))
        case "draft_app_block":
            return .blockDraft(BlockDraft(toolArgs: message.toolArgs))
        // ask_follow_up deliberately has no card: the question is the
        // message text, and the parent answers by typing. Offering tappable
        // answers turned an open question into multiple choice and put the
        // model back to guessing at what the task might be.
        case "ask_follow_up": return nil
        // Anything else is a tool the assistant no longer has (courses,
        // reflections, blocks) on an older message: shown as its text, with
        // no card to act on.
        default: return nil
        }
    }

    private func reloadConversations() async {
        guard let childId = session.activeChildId else { return }
        conversations = (try? await APIClient.shared.fetchConversations(childId: childId)) ?? conversations
    }

    private func openConversation(_ id: String) async {
        guard let loaded = try? await APIClient.shared.fetchConversationMessages(conversationId: id) else { return }
        activeConversationID = id
        messages = Self.groupedTaskDrafts(loaded.map { m in
            ChatMessage(fromUser: m.role == "user", text: m.text, card: m.toolCall != nil ? cardFor(m) : nil,
                        agent: m.agent ?? "chat")
        })
        // A reopened thread can't know which drafts were already used, so
        // only the newest reply's stay open; earlier ones fold away rather
        // than offering Create again on something likely already created.
        let lastUser = messages.lastIndex(where: \.fromUser) ?? -1
        for i in messages.indices where i < lastUser && isDraft(messages[i].card) {
            messages[i].superseded = true
        }
        // A thread with the same number of messages as the last one doesn't
        // trip the messages.count scroll, so ask for it outright.
        scrollRequest.count += 1
        scrollRequest.target = .bottom
        scrollRequest.animated = false
    }

    private func renameConversation(_ conversation: ApiChatConversation, to title: String) async {
        guard (try? await APIClient.shared.renameConversation(conversationId: conversation.id, title: title)) != nil
        else { return }
        await reloadConversations()
    }

    private func deleteConversation(_ conversation: ApiChatConversation) async {
        guard (try? await APIClient.shared.deleteConversation(conversationId: conversation.id)) != nil
        else { return }
        // Deleting the thread you're reading leaves the transcript showing
        // something that no longer exists, so drop to a fresh one.
        if activeConversationID == conversation.id {
            activeConversationID = nil
            messages = []
        }
        await reloadConversations()
    }


    // Used to only append a canned confirmation string — never actually
    // called APIClient.shared.createTask, so tapping Create on this card
    // never created a real task at all, independent of any AI work here.
    // `due` (from AddTaskCard's free-text field, e.g. "6pm" or "Saturday
    // morning") isn't structured enough to convert into a real due
    // date/time reliably — sending a wrong guess would be worse than
    // sending none, so the created task just has no due date/time, same
    // as when a parent skips "More Options" anywhere else in this app.
    // `repeats` (from inferredRepeats.codes) is already a real recurrence
    // code ("mon,wed,fri"/"daily"/"none") and is used as-is.
    /// A fresh, empty chat: from the top bar or the history panel. Nothing
    /// is created on the server until the first message (see chat.py), so
    /// tapping it by accident leaves no empty thread behind.
    private func startNewChat() {
        newChatTick += 1
        responseTask?.cancel()
        isSending = false
        inputFocused = false
        activeConversationID = nil
        withAnimation(.easeOut(duration: 0.2)) { messages = [] }
    }

    private func isDraft(_ card: ChatCardKind?) -> Bool {
        switch card {
        case .addTask, .addTasks, .blockDraft: return true
        default: return false
        }
    }

    private func draftTitle(_ card: ChatCardKind) -> String {
        switch card {
        case .addTask(let d): return d.title.isEmpty ? "a task" : d.title
        case .blockDraft(let d): return "block \(d.appName ?? "an app")"
        case .addTasks(let ds): return "\(ds.count) tasks"
        default: return "a card"
        }
    }

    /// Before a new reply's drafts land: fold every earlier draft that
    /// nothing was created from, so only the newest is there to act on.
    private func foldUnusedDrafts() {
        for i in messages.indices where isDraft(messages[i].card) && !messages[i].cardDone {
            messages[i].superseded = true
        }
    }

    private func unfold(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { messages[i].superseded = false }
    }

    /// A card was used: it's done at once (no second Create), shows its done
    /// state for a moment, then collapses into one line saying what it did,
    /// as ChatGPT and Claude do with a confirmed action. That line replaces
    /// the separate "Added …" message cards used to post.
    /// A reply's card, or the receipt it collapsed into once used.
    @ViewBuilder
    private func cardArea(for m: ChatMessage) -> some View {
        if let receipt = m.receipt {
            receiptView(receipt)
                .transition(.opacity)
        } else if let card = m.card {
            cardView(for: card, in: m.id, done: m.cardDone)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                // A card the parent opens up (Change, Custom, a field added)
                // grows past the composer; bring the grown part into view,
                // for the newest card only.
                .modifier(GrowthWatcher { cardGrew(m) })
        }
    }

    private func cardGrew(_ m: ChatMessage) {
        guard !m.cardDone, m.id == messages.last?.id else { return }
        userScrolledSinceSend = false
        scrollRequest.count += 1
        scrollRequest.target = .reveal
        scrollRequest.animated = true
    }

    private func receiptView(_ r: ChatReceipt) -> some View {
        HStack(spacing: 12) {
            switch r.icon {
            case .app(let name):
                AppIconView(appName: name, size: 34)
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(ChatType.strong(15))
                    .foregroundStyle(EColor.onSurface)
                    .lineLimit(1)
                Text(r.detail)
                    .font(ChatType.label(13))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .background(EColor.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func markDone(_ id: UUID, receipt: ChatReceipt) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].cardDone = true
        addedTick += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let j = messages.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.25)) { messages[j].receipt = receipt }
        }
    }

    /// A card-only row right after another reply row: a further card from
    /// the same answer, drawn closer to the one before it.
    private func continuesReply(_ m: ChatMessage) -> Bool {
        guard !m.fromUser, m.text.isEmpty, m.card != nil,
              let i = messages.firstIndex(where: { $0.id == m.id }), i > 0 else { return false }
        return !messages[i - 1].fromUser
    }

    private func endEditing() {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .endEditing(true)
    }

    /// Task drafts that arrived as rows of one reply (the first carrying the
    /// text, the rest card-only) become one several-task card. A lone task
    /// keeps its own card; other cards are left as they are.
    private static func groupedTaskDrafts(_ rows: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for row in rows {
            if case .addTask(let draft) = row.card, !row.fromUser, row.text.isEmpty, let last = out.last, !last.fromUser {
                switch last.card {
                case .addTask(let first):
                    out[out.count - 1].card = .addTasks(drafts: [first, draft])
                    continue
                case .addTasks(let drafts):
                    out[out.count - 1].card = .addTasks(drafts: drafts + [draft])
                    continue
                default: break
                }
            }
            out.append(row)
        }
        // The server's line for several cards; tasks say it their own way.
        for i in out.indices {
            if case .addTasks(let drafts) = out[i].card, out[i].text.hasPrefix("Here are ") {
                out[i].text = "Here are \(drafts.count) tasks."
            }
        }
        return out
    }

    /// Creates the ticked tasks; returns the line the card collapses into.
    private static let taskTint = Color(hex: "3B6FD8")

    private func handleAddTasks(_ drafts: [TaskDraft]) -> ChatReceipt {
        let made = drafts.filter { !$0.isEmpty }
        guard !made.isEmpty, session.activeChildId != nil else {
            return ChatReceipt(icon: .symbol("checklist", Self.taskTint), title: "Nothing added", detail: "")
        }
        made.forEach(createTask)
        Task { await AppSync.shared.syncBackendData() }
        return ChatReceipt(icon: .symbol("checklist", Self.taskTint),
                           title: made.count == 1 ? "1 task added" : "\(made.count) tasks added",
                           detail: made.map(\.title).joined(separator: ", "))
    }

    private func handleAddTask(_ draft: TaskDraft) -> ChatReceipt {
        guard !draft.isEmpty, session.activeChildId != nil else {
            return ChatReceipt(icon: .symbol("checklist", Self.taskTint), title: "Nothing added", detail: "")
        }
        createTask(draft)
        Task { await AppSync.shared.syncBackendData() }
        return ChatReceipt(icon: .symbol("checklist", Self.taskTint), title: draft.title,
                           detail: "Task added · " + TaskBatchCard.when(draft))
    }

    private func createTask(_ draft: TaskDraft) {
        guard !draft.isEmpty, let childId = session.activeChildId else { return }
        // Queued like every other write; a refusal shows the app's save
        // error. The sync sends it and brings it onto Home and the calendar.
        TaskEdits.create(
            childId: childId, title: draft.title, instructions: draft.instructions,
            recurrence: draft.recurrence, category: "Chore",
            dueTime: draft.dueTimeString, dueDate: draft.dueDateString,
            bonusMinutes: draft.bonusMinutes, createdBy: "ai_agent",
            icon: draft.emoji
        )
    }

    /// Says back what was actually saved, including the schedule — so a
    /// wrong date is visible immediately rather than discovered later on the
    /// calendar.
    private func confirmation(for draft: TaskDraft, title: String) -> String {
        var parts: [String] = []
        if let date = draft.dueDate {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(date) || Calendar.current.isDateInTomorrow(date)
                ? "EEEE" : "EEEE d MMM"
            parts.append(Calendar.current.isDateInToday(date) ? "today"
                         : Calendar.current.isDateInTomorrow(date) ? "tomorrow"
                         : "on \(f.string(from: date))")
        }
        if let minutes = draft.dueMinutes {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())
            parts.append("at \(f.string(from: d ?? Date()))")
        }
        if draft.recurrence != "none" {
            parts.append("repeating \(repeatDisplayLabel(draft.recurrence).lowercased())")
        }
        let when = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        return "Added \"\(title)\"\(when)."
    }

    @ViewBuilder
    private func cardView(for kind: ChatCardKind, in messageID: UUID, done: Bool) -> some View {
        switch kind {
        case .blockDraft(let draft):
            AppBlockDraftCard(draft: draft, childId: session.activeChildId ?? "", done: done) { app, length in
                markDone(messageID, receipt: ChatReceipt(icon: .app(app), title: "\(app) blocked", detail: length))
            }
        case .addTask(let draft):
            AddTaskCard(draft: draft, done: done) { made in
                markDone(messageID, receipt: handleAddTask(made))
            }
        case .addTasks(let drafts):
            TaskBatchCard(drafts: drafts, done: done) { made in
                markDone(messageID, receipt: handleAddTasks(made))
            }
        case .reviewCompliance(let childId, let childName):
            ReviewComplianceCard(childId: childId, childName: childName)
        }
    }

    // Every path that produces an assistant reply — a card appended after a
    // short "typing" delay, or a streamed-in text reply — funnels through
    // here so there is only ever one response in flight. Previously each
    // path scheduled its own independent DispatchQueue.main.asyncAfter with
    // nothing cancelling an earlier one: firing a second action (another
    // suggestion tile, a thread switch) while the first was still mid-delay
    // or mid-stream could leave two of these writing into `messages` at
    // once — the likely cause of a stuck typing indicator sitting over an
    // already-appended card. A structured Task, cancelled up front, means
    // starting a new response always wins outright instead of racing.
    private func beginResponse(afterSeconds seconds: Double, _ produceReply: @escaping () -> Void) {
        responseTask?.cancel()
        isSending = true
        responseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isSending = false
            produceReply()
        }
    }

    // Stand-in for a real backend call: after the typing-dots delay, appends
    // one empty assistant message, then streams words into it (Gemini/
    // ChatGPT-style) rather than popping the whole reply in at once. A real
    // backend integration would replace the word-splitting/sleep below with
    // appending each chunk as it arrives over the wire.
    private func respondAfterDelay(with text: String) {
        beginResponse(afterSeconds: 0.9) {
            messages.append(ChatMessage(fromUser: false, text: ""))
            guard let id = messages.last?.id else { return }
            streamIn(text, into: id)
        }
    }

    // The empty-message append above scrolls once, while the reply is
    // still empty; after that it grows downward behind the composer, so
    // each word re-scrolls — but only while the parent is following the
    // bottom, never if they've scrolled up to read.
    // Takes over `responseTask` for its own duration, so it's cancelled the
    // same way the delay before it was — a thread switch mid-stream stops
    // writing into a transcript that's no longer showing, rather than a
    // pile of independent timers that fire regardless of what changed.
    private func streamIn(_ fullText: String, into id: UUID) {
        let words = fullText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        isStreaming = true
        responseTask = Task { @MainActor in
            // Also on cancel: switching threads mid-reply cancels this task
            // without going through stopReply.
            defer { isStreaming = false }
            for i in words.indices {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
                messages[idx].text = words[...i].joined(separator: " ")
            }
            announce(fullText)
        }
    }
}

private struct HelpPanel: View {
    @Environment(\.dismiss) private var dismiss
    // While a reply is still coming, shortcuts can't start another one
    // (the tiles are disabled then too).
    var isBusy = false
    // Runs a shortcut exactly as tapping its tile on the start screen does.
    var onPick: (ChatSuggestion) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    helpSection("Shortcuts") {
                        // The same list, icons and titles as the start
                        // screen's tiles, so what's explained here is
                        // exactly what's on screen there.
                        ForEach(welcomeSuggestions) { s in
                            Button { onPick(s) } label: {
                                helpRow(icon: s.icon, tint: s.tint, title: s.title, text: s.help, tappable: true)
                            }
                            .buttonStyle(HelpRowButtonStyle())
                            .disabled(isBusy)
                            .accessibilityHint("Starts this in the chat")
                        }
                    }

                    helpSection("Good to know") {
                        ForEach(capabilities) { c in
                            helpRow(icon: c.icon, tint: c.tint, title: c.title, text: c.sub)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("What Evlin can do")
            .presentationDragIndicator(.visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }

    private func helpSection<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(ChatType.label(11.5))
                .tracking(0.8)
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(EColor.surfaceContainerLowest)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(EColor.outlineVariant))
        }
    }

    // Each icon bare, in its shortcut's own colour (the same as its tile),
    // sitting on the title's line: no backing shape, so the colour and the
    // words carry the row.
    private func helpRow(icon: String, tint: Color, title: String, text: String, tappable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: EIcon.sf(icon))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(ChatType.label(16))
                    .tracking(-0.3)
                    .foregroundStyle(EColor.onSurface)
                Text(text)
                    .font(ChatType.label(13.5))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(EColor.outline.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// A list row's press state: the row tints while held, like a system list
// cell, and the whole row fades when it can't be used.
private struct HelpRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? EColor.surfaceContainerHigh : Color.clear)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Chat history

// A collapsible left sidebar over the chat canvas — the ChatGPT/Claude
// desktop pattern (fixed-width history rail + centered conversation) adapted
// to a phone: an overlay drawer instead of a permanent split view, since
// there's no room to show both panes at once on this width. Keeps Gemini's
// floating rounded row "cards" over a per-row "•••" menu for rename/delete,
// plus a tinted pill on whichever entry is currently loaded into the
// transcript (the "active state" from the desktop reference).
// A chat toolbar button's glyph: no backing circle, with a full-size tap
// target. Shared by the chat screen and its history panel, so the button
// is the same in both. Light and a soft dark grey: at full black and a
// heavy weight, a bare glyph shouted louder than anything on the screen.
private func chatToolbarIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(EColor.onSurface.opacity(0.7))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
}

private struct ChatHistorySidebar: View {
    var selectedID: String?
    var conversations: [ApiChatConversation]
    var onSelect: (ApiChatConversation) -> Void
    var onNewChat: () -> Void
    var onRename: (ApiChatConversation, String) -> Void
    var onDelete: (ApiChatConversation) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var renamingEntry: ApiChatConversation?
    @State private var renameText = ""
    // Lets a finger drag the whole panel toward its exit edge (matching the
    // .move(edge: .leading) transition it entered with) instead of the x/
    // sidebar button being the only way out — dragged part-way then
    // released short of the threshold springs back rather than committing.
    @State private var dragOffset: CGFloat = 0

    private var filtered: [ApiChatConversation] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    // "Chats" and the close button sit in a navigation bar like the chat
    // screen's, so they're level with its buttons, and the button is drawn
    // at the same size (chatToolbarIcon). White like the chat screen.
    var body: some View {
        NavigationStack {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(EColor.surface)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("Chats")
                            .font(ChatType.label(20))
                            .foregroundStyle(EColor.onSurface)
                            .fixedSize()
                            .padding(.leading, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .flatToolbarBackground()
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onClose) { chatToolbarIcon("sidebar.leading") }
                            .buttonStyle(PressedFadeStyle())
                            .accessibilityLabel("Close chat history")
                    }
                    .flatToolbarBackground()
                }
        }
        .offset(x: min(0, dragOffset))
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    // Predominantly-horizontal only, so this doesn't fight
                    // the ScrollView's own vertical drag for scrolling.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < 0 { dragOffset = value.translation.width }
                }
                .onEnded { value in
                    let dismiss = value.translation.width < -80 || value.predictedEndTranslation.width < -160
                    if dismiss {
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                    }
                }
        )
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.top, 8)

            if filtered.isEmpty {
                Spacer()
                Text("No conversations found")
                    .font(ChatType.label(15))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if query.isEmpty {
                            newChatRow
                        }
                        // One list, newest first, with no "Today" / "Yesterday"
                        // / "Previous 7 days" headings; each row's own time
                        // label says when.
                        VStack(spacing: 3) {
                            ForEach(filtered) { entry in
                                row(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingEntry = nil }
            Button("Save") {
                if let entry = renamingEntry {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onRename(entry, trimmed) }
                }
                renamingEntry = nil
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(EColor.onSurfaceVariant)
            TextField("Search conversations", text: $query)
                .font(ChatType.label(15))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(EColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var newChatRow: some View {
        Button(action: onNewChat) {
            HStack(spacing: 14) {
                Circle()
                    .fill(EColor.primaryContainer)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(EColor.primary)
                    )
                Text("New chat")
                    .font(ChatType.label(15))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressedSurfaceStyle())
    }

    private func row(_ entry: ApiChatConversation) -> some View {
        let isActive = entry.id == selectedID
        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(ChatType.label(15))
                        .foregroundStyle(EColor.onSurface)
                        .lineLimit(1)
                    Text(entry.timeLabel)
                        .font(ChatType.label(12))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
                Spacer(minLength: 4)

                Menu {
                    Button {
                        renameText = entry.title
                        renamingEntry = entry
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            // The tinted pill is the only "which thread am I looking at"
            // signal in a drawer this narrow — mirrors the selected-row
            // highlight in ChatGPT/Claude's sidebar.
            .background(isActive ? EColor.primaryContainer : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressedSurfaceStyle())
    }
}

// The send button dips slightly under the finger and springs back.
// What a press looks like in chat. A plain button showed nothing while
// held, so a tap felt like it hadn't landed. Quick and without bounce:
// it's acknowledging a finger, not celebrating.
/// Cards, tiles, rows and primary buttons: shrink a touch and dim.
struct PressedSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.18), value: configuration.isPressed)
    }
}

/// Icons and text buttons: fade while held.
struct PressedFadeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.4 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.18), value: configuration.isPressed)
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private extension View {
    /// Calls `action` when the parent starts dragging a scroll view. iOS 18
    /// reports that directly; on 17 there's no clean signal (a drag gesture
    /// on a scroll view fights its scrolling), so it's never called there.
    @ViewBuilder
    func onUserScroll(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, phase in
                if phase == .interacting { action() }
            }
        } else {
            self
        }
    }
}

private extension ToolbarContent {
    // iOS 26 gives every bar button a shared glass background; the chat's
    // icons draw their own flat one instead. Earlier systems have no glass.
    @ToolbarContentBuilder
    func flatToolbarBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
