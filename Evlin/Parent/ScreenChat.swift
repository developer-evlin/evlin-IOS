import SwiftUI

// What Evlin-iOS's actual chat cards look like: mostly plain
// icon+title+body+buttons (PlanArchCardView), or read-only confirm lists
// (BulkActionCard) — there's no searchable app picker in production at all;
// app blocking there goes through Apple's native FamilyActivityPicker
// outside the card system entirely, and "add task" is copy + Approve/Cancel
// with no structured fields. These two are built for real here instead of
// port-for-port, reusing this app's own AddTaskSheet fields.
private enum ChatCardKind {
    case blockApp
    // A separate follow-up turn, not a section inside BlockAppCard — picking
    // apps and picking a duration read as two questions asked one after the
    // other, matching how a real back-and-forth conversation would ask them,
    // rather than both showing up on the same card at once.
    case blockDuration(apps: [String])
    // Carries the message that triggered it — AddTaskCard reads this to
    // pre-fill Title/Due the same way inferredRepeats already reads typed
    // text for a repeat cadence, so tapping a specific request ("...to
    // clean his room every Saturday morning") hands back a drafted task to
    // confirm/edit rather than a blank form the parent re-types by hand.
    case addTask(prompt: String)
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
private let bubbleMaxWidth: CGFloat = 300

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
                    inline(String(line.dropFirst(3))).font(Typography.font(17, weight: .bold)).padding(.top, 2)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2))).font(Typography.font(20, weight: .heavy)).padding(.top, 2)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(EColor.onSurfaceVariant).frame(width: 4, height: 4).padding(.top, 9)
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
        return t.lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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

// Row shape (icon, name, trailing checkbox) is closest to Evlin-iOS's
// U1Card (unlock_picker), adapted for picking targets to block instead of
// unlock. The Apps/Categories tab split and search field mirror
// LockListManagerView's real section layout.
private struct BlockAppCard: View {
    // Just the target pick — duration is its own follow-up turn
    // (BlockDurationCard below), not a section tacked onto this same card.
    var onSelectTargets: ([String]) -> Void

    @State private var query = ""
    @State private var selectedApps: Set<UUID> = []
    @State private var submitted = false

    private var totalSelected: Int { selectedApps.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(EColor.danger)
                Text("Block an app").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }

            BlockTargetPicker(query: $query, selectedApps: $selectedApps)
                .disabled(submitted)

            Button {
                let appNames = mockAppCatalog.filter { selectedApps.contains($0.id) }.map(\.name)
                submitted = true
                onSelectTargets(appNames)
            } label: {
                Text(totalSelected == 0 ? "Select apps to block" : "Block \(totalSelected) selected")
                    .font(Typography.font(13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(totalSelected == 0 || submitted ? EColor.outlineVariant : EColor.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(totalSelected == 0 || submitted)
        }
        .padding(14)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
    }
}

// The follow-up turn to BlockAppCard — asked as its own question once the
// apps are picked, the way a real back-and-forth would ask it, rather than
// bundling both choices onto one card.
private struct BlockDurationCard: View {
    var apps: [String]
    var onConfirm: (Int?) -> Void

    @State private var duration: Int? = nil
    // nil duration is itself a real answer ("until I unlock it"), so
    // whether a choice has been made needs its own flag distinct from that.
    @State private var chosen = false
    @State private var submitted = false

    private let options: [Int?] = [15, 30, 60, 120, 240, nil]

    private func label(_ minutes: Int?) -> String {
        guard let minutes else { return "Until I unlock it" }
        return formatMinutes(minutes)
    }

    private var appList: String {
        apps.count == 1 ? apps[0] : apps.dropLast().joined(separator: ", ") + " and " + (apps.last ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.fill").font(.system(size: 15)).foregroundStyle(EColor.danger)
                Text("For how long?").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }
            Text(appList)
                .font(Typography.font(12.5, weight: .medium))
                .foregroundStyle(EColor.onSurfaceVariant)

            FlowChips {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isSelected = chosen && duration == option
                    Button {
                        duration = option
                        chosen = true
                    } label: {
                        Text(label(option))
                            .font(Typography.font(12, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : EColor.onSurface)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(isSelected ? EColor.danger : EColor.surfaceContainerHigh)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(submitted)
                }
            }

            Button {
                submitted = true
                onConfirm(duration)
            } label: {
                Text(chosen ? "Block for \(label(duration))" : "Choose how long")
                    .font(Typography.font(13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(chosen && !submitted ? EColor.danger : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!chosen || submitted)
        }
        .padding(14)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
    }
}

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
    var initialPrompt: String = ""
    var onCreate: (_ title: String, _ whatToDo: String, _ due: String, _ repeats: String) -> Void

    @State private var title: String
    @State private var whatToDo = ""
    @State private var due: String
    @State private var submitted = false

    init(initialPrompt: String = "", onCreate: @escaping (_ title: String, _ whatToDo: String, _ due: String, _ repeats: String) -> Void) {
        self.initialPrompt = initialPrompt
        self.onCreate = onCreate
        let parsed = Self.parse(initialPrompt)
        _title = State(initialValue: parsed.title)
        _due = State(initialValue: parsed.due)
    }

    // Crude "...to <task> every/on/at <schedule>" extraction — good enough
    // for the specific, realistic requests this card is actually shown
    // from (the chat suggestion tile, or a parent's own typed request);
    // anything that doesn't match this shape just leaves both fields
    // blank, same as before this existed.
    private static func parse(_ prompt: String) -> (title: String, due: String) {
        guard let toRange = prompt.range(of: " to ", options: .caseInsensitive) else { return ("", "") }
        let after = String(prompt[toRange.upperBound...])
        let lower = after.lowercased()
        for marker in ["every ", " on ", " at "] {
            if let r = lower.range(of: marker) {
                let titlePart = String(after[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let duePart = String(after[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
                return (capitalizeFirst(titlePart), capitalizeFirst(duePart))
            }
        }
        return (capitalizeFirst(after), "")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !submitted }

    // Simple keyword scan over what's typed so far — stands in for real
    // language understanding the same way this whole chat's "AI" is
    // mocked elsewhere (see respondAfterDelay). Checked in order: an
    // explicit weekday/weekend cue wins over a bare "every day", which
    // wins over the one-time default.
    // Named weekdays checked first — "every Tuesday and Thursday" should
    // read as exactly that, not fall through to a vaguer daily/weekday
    // bucket. Gives free-typed text the same day-by-day expressiveness the
    // old manual bubble picker had, instead of only the three canned
    // buckets below it.
    private let namedWeekdays: [(name: String, code: String)] = [
        ("sunday", "sun"), ("monday", "mon"), ("tuesday", "tue"), ("wednesday", "wed"),
        ("thursday", "thu"), ("friday", "fri"), ("saturday", "sat"),
    ]

    private var inferredRepeats: (label: String, codes: String) {
        let text = "\(title) \(whatToDo) \(due)".lowercased()

        let mentioned = namedWeekdays.filter { text.contains($0.name) }
        if !mentioned.isEmpty {
            let codes = weekDayCodes.filter { code in mentioned.contains { $0.code == code } }
            let codeString = codes.joined(separator: ",")
            return ("Repeats \(repeatDisplayLabel(codeString))", codeString)
        }
        if text.contains("weekend") {
            return ("Repeats weekends", "sat,sun")
        }
        if text.contains("school night") || text.contains("school day") || text.contains("weekday") {
            return ("Repeats on weekdays", "mon,tue,wed,thu,fri")
        }
        if text.contains("every day") || text.contains("everyday") || text.contains("each day") || text.contains("daily") || text.contains("every night") {
            return ("Repeats daily", "sun,mon,tue,wed,thu,fri,sat")
        }
        return ("One-time task", "none")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 15)).foregroundStyle(EColor.primary)
                Text("Add a task").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }

            cardField(label: "Title") {
                TextField("e.g. Read for 20 minutes", text: $title)
                    .font(Typography.font(13.5, weight: .regular))
            }

            cardField(label: "What to do") {
                TextField("Instructions…", text: $whatToDo, axis: .vertical)
                    .font(Typography.font(13.5, weight: .regular))
                    .lineLimit(2...4)
            }

            cardField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM, or every school night", text: $due)
                    .font(Typography.font(13.5, weight: .regular))
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text(inferredRepeats.label)
            }
            .font(Typography.font(11.5, weight: .semibold))
            .foregroundStyle(EColor.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(EColor.primaryContainer)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: inferredRepeats.label)

            Button {
                submitted = true
                onCreate(title, whatToDo, due, inferredRepeats.codes)
            } label: {
                Text("Create task")
                    .font(Typography.font(13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(canCreate ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(14)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
        .disabled(submitted)
    }

    @ViewBuilder
    private func cardField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Typography.font(10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(EColor.onSurfaceVariant)
            content()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(EColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// AI "reads" the child's real task list and reports what's done vs. still
// outstanding — replaces the old one-tap "lock this app" suggestion with a
// status readout, matching the parent's actual ask (what did they finish,
// not what should I block).
private struct ReviewComplianceCard: View {
    let childId: String
    let childName: String

    private var tasks: [ChildTask] { TaskStore.tasks(for: childId) }
    private var done: [ChildTask] { tasks.filter { $0.state == .done } }
    private var overdue: [ChildTask] { tasks.filter { $0.state == .overdue } }
    private var outstanding: [ChildTask] { tasks.filter { $0.state == .pending || $0.state == .review || $0.state == .overdue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(EColor.primary)
                Text("\(childName)'s progress").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }

            HStack(spacing: 8) {
                statPill(value: "\(done.count)", label: "Done", tint: Brand.greenDeep)
                statPill(value: "\(outstanding.count - overdue.count)", label: "Pending", tint: EColor.onSurfaceVariant)
                statPill(value: "\(overdue.count)", label: "Overdue", tint: EColor.danger)
            }

            if overdue.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    Text(tasks.isEmpty ? "No tasks assigned yet." : "Nothing overdue — on track today.")
                }
                .font(Typography.font(12.5, weight: .semibold))
                .foregroundStyle(Brand.greenDeep)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEEDS ATTENTION")
                        .font(Typography.font(10.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(EColor.onSurfaceVariant)
                    ForEach(overdue) { task in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(EColor.danger)
                            Text(task.title)
                                .font(Typography.font(13, weight: .medium))
                                .foregroundStyle(EColor.onSurface)
                            Spacer()
                            if let due = task.dueLabel {
                                Text(due)
                                    .font(Typography.font(11, weight: .regular))
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
        .padding(14)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
    }

    private func statPill(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Typography.font(17, weight: .heavy)).foregroundStyle(tint)
            Text(label.uppercased()).font(Typography.font(9.5, weight: .bold)).tracking(0.4).foregroundStyle(EColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(EColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct Capability: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var sub: String
}

private let capabilities: [Capability] = [
    Capability(icon: "apps", title: "Control apps in real time", sub: "Lock, unlock, or add time to any app right from the chat — no need to leave the conversation."),
    Capability(icon: "gavel", title: "Turn a sentence into a rule", sub: "Type a consequence or limit in plain English and Evlin sets it up as a lasting rule."),
    Capability(icon: "figure.mind.and.body", title: "Guide de-escalation", sub: "When a lock triggers pushback, Evlin suggests an in-the-moment strategy backed by child psychology."),
    Capability(icon: "note.text", title: "Collect & summarize reflections", sub: "After a consequence, Evlin has your child reflect — then surfaces what happened and why."),
    Capability(icon: "chart.line.uptrend.xyaxis", title: "Spot patterns in behavior", sub: "Evlin notices trends like late-night gaming and proactively flags them before they become habits."),
    Capability(icon: "location.fill", title: "Answer 'where are they'", sub: "Ask about a child's location or day and Evlin pulls it into the conversation."),
]

private let welcomeMessage = ChatMessage(fromUser: false, text: "Hi! I'm Evlin. I can control apps, set rules, and help with in-the-moment strategies — right from this chat.")

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
    // its own intro text in sendSuggestion instead (see .blockApp/.addTask/
    // .reviewCompliance there). Lets a plain-text suggestion (no structured
    // follow-up) still land a reply tailored to what it actually asked,
    // rather than every one of them collapsing onto the same generic
    // "Got it — I'll take care of that." line.
    var reply: String? = nil
}

@MainActor
private var welcomeSuggestions: [ChatSuggestion] {[
    ChatSuggestion(icon: "sf:checkmark.seal.fill", title: "Review your child's progress", prompt: "How is your child doing with his tasks today?", card: .reviewCompliance(childId: SessionManager.shared.activeChildId ?? "", childName: "your child")),
    ChatSuggestion(icon: "gavel", title: "Set a bedtime rule", prompt: "Lock all apps at 9pm on school nights"),
    ChatSuggestion(
        icon: "sf:checklist", title: "Add a task",
        prompt: "Add a task for your child to clean his room every Saturday morning",
        card: .addTask(prompt: "Add a task for your child to clean his room every Saturday morning")
    ),
    ChatSuggestion(icon: "sf:nosign", title: "Block an app", prompt: "Block an app for your child", card: .blockApp),
    ChatSuggestion(
        icon: "sf:lightbulb.fill", title: "Suggest an activity",
        prompt: "Suggest something your child can do instead of screen time",
        reply: "A 20-minute LEGO build or a walk around the block both work well right after school — want me to add one to today's tasks?"
    ),
    // No hardcoded `reply:` here (used to claim "Added — Soccer Practice
    // now repeats..." with nothing ever actually written to the
    // calendar) — this now goes to the real model like any other
    // freeform message, which (per its system prompt) says honestly
    // that it can't add calendar events yet rather than fabricating a
    // "done" reply.
    ChatSuggestion(
        icon: "sf:calendar", title: "Update the calendar",
        prompt: "Add soccer practice to your child's calendar every Thursday at 4pm"
    ),
]}

struct ScreenChat: View {
    @Environment(SessionManager.self) private var session

    // No canned "I'm Evlin" bubble seeded in — the empty state's welcomeGrid
    // already carries that greeting, so the transcript itself only ever
    // holds real exchanges the user actually sent/received.
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
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
    @State private var selectedEntryID: UUID?
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

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack, not VStack: this list can grow long over a
                    // real conversation, and only rows on/near screen should
                    // be built.
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if messages.isEmpty {
                            // Empty-conversation state: a Gemini/ChatGPT-style
                            // prompt grid — replaced by (not layered under)
                            // the transcript once a real exchange starts,
                            // each swapping in with its own transition rather
                            // than a flat cut.
                            welcomeGrid
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                ))
                        }

                        if !messages.isEmpty {
                            // 24pt between turns — spacing is what
                            // separates messages now that nothing's drawn
                            // around the assistant's replies.
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(messages) { m in
                                    if m.fromUser {
                                        // The one bubble left: dark fill,
                                        // rounded, right-aligned, hugging
                                        // its content. Keeping this
                                        // asymmetric against the
                                        // assistant's plain text below is
                                        // what makes the two speakers
                                        // distinguishable at all now.
                                        HStack {
                                            Spacer(minLength: 40)
                                            MessageContent(text: m.text)
                                                .font(Typography.font(13, weight: .medium))
                                                .foregroundStyle(.white)
                                                .padding(12)
                                                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                                                .background(EColor.primary)
                                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                        }
                                        .id(m.id)
                                        .transition(messageTransition)
                                    } else {
                                        // No card, no border, no fill, no
                                        // avatar — text laid directly on the
                                        // chat background, full width,
                                        // left-aligned. Turn spacing alone
                                        // (24pt, above) is what separates
                                        // this from the message before it —
                                        // exactly the Gemini/ChatGPT read.
                                        Group {
                                            if let card = m.card {
                                                // The intro line + the card are one
                                                // message — matches how a real card
                                                // reply reads as a single turn, not
                                                // two separate messages.
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text(m.text)
                                                        .font(Typography.font(15, weight: .regular))
                                                        .lineSpacing(3)
                                                        .foregroundStyle(EColor.onSurface)
                                                    cardView(for: card)
                                                }
                                            } else {
                                                MessageContent(text: m.text)
                                                    .font(Typography.font(15, weight: .regular))
                                                    .foregroundStyle(EColor.onSurface)
                                                    // Gemini/ChatGPT-style streaming reveal (see
                                                    // respondAfterDelay) — as words get appended
                                                    // to `m.text`, the text smoothly grows into
                                                    // its new size instead of snapping.
                                                    .animation(.easeOut(duration: 0.16), value: m.text)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(m.id)
                                        .transition(messageTransition)
                                    }
                                }

                                if isSending {
                                    TypingIndicator()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("typing")
                                        .transition(.opacity)
                                }
                            }
                        }

                        // Zero-height anchor scrollTo always targets, so
                        // "scroll to newest" means the same thing whether
                        // the last row is a real message or the typing dots.
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
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
                }
                .coordinateSpace(name: chatScrollSpace)
                // Plain white — Home, Calendar, and Settings all use it as
                // their root ground; EColor.surface's faint off-white cast
                // was the one tab that read as a slightly different shade.
                .background(Color.white)
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
                .onPreferenceChange(ChatScrollOffsetKey.self) { newOffset in
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
                    inputBar
                }
                // Native initial-position anchoring (iOS 17+) instead of a
                // manual scrollTo in .onAppear: calling scrollTo before the
                // LazyVStack finishes its first layout pass — which got much
                // more likely once card messages made the transcript tall —
                // could land the offset past all content, rendering as a
                // fully blank scroll view until the user manually scrolled.
                // defaultScrollAnchor sidesteps the race entirely by letting
                // SwiftUI itself resolve the starting position after layout.
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) { _, _ in scrollToBottom(proxy, animated: true) }
                .onChange(of: isSending) { _, _ in scrollToBottom(proxy, animated: true) }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        inputFocused = false
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = true }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .accessibilityLabel("Chat history")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
            }
            // Instagram-style collapse on scroll (see chromeHidden) — hides
            // both this screen's own nav bar and, since a tab's content can
            // declare its own tab-bar visibility independent of the other
            // tabs, ParentRootView's tab bar too, purely from in here.
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar(chromeHidden ? .hidden : .visible, for: .tabBar)
        }
        .sheet(isPresented: $showHelp) { HelpPanel() }
        // Full-screen history (Gemini's pattern, not a partial-width drawer)
        // — the conversation canvas stays mounted behind it so closing never
        // re-triggers the transcript's own appear animation.
        .overlay {
            if showHistory {
                ChatHistorySidebar(
                    selectedID: selectedEntryID,
                    onSelect: { entry in
                        // Cancel first — an in-flight response belongs to
                        // whatever thread was showing when it started, and
                        // has no business appending into a different one.
                        responseTask?.cancel()
                        isSending = false
                        selectedEntryID = entry.id
                        messages = entry.transcript.map { ChatMessage(fromUser: $0.fromUser, text: $0.text) }
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = false }
                    },
                    onNewChat: {
                        responseTask?.cancel()
                        isSending = false
                        selectedEntryID = nil
                        messages = []
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = false }
                    },
                    onClose: { withAnimation(.easeOut(duration: 0.22)) { showHistory = false } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EColor.surface.ignoresSafeArea())
                .transition(.move(edge: .leading))
            }
        }
        // Real persisted history — replaces the old empty-on-every-launch
        // transcript (chatHistoryMock only ever backed the separate
        // multi-thread sidebar, never this main view).
        .task { await loadHistory() }
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

    // Applied to every message row so a new one slides/fades in from the
    // bottom on arrival (matching the send/receive rhythm of a real
    // conversation) rather than just snapping into the LazyVStack's layout.
    private var messageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    // Empty-conversation grid — the Gemini/ChatGPT "here's what to try"
    // pattern: greeting up top, then a 2-column grid of ready-to-run
    // prompts instead of a lone welcome bubble.
    private var welcomeGrid: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(EColor.primary)
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "flame.fill").font(.system(size: 27)).foregroundStyle(Color(hex: "8CE6A8")))
                Text("Hi, I'm Evlin")
                    .font(Typography.font(25, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                Text(welcomeMessage.text)
                    .font(Typography.font(14, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 36)

            // Only 4 tiles now (Pushback/Location were cut), which is exactly
            // one clean 2x2 — sized up from the old 6-tile grid's cramped
            // 100pt rows so the empty state reads as roomy, not a leftover
            // grid with two slots removed.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(welcomeSuggestions) { s in
                    Button { sendSuggestion(s) } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: EIcon.sf(s.icon))
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(EColor.primary)
                            Text(s.title)
                                .font(Typography.font(14.5, weight: .semibold))
                                .foregroundStyle(EColor.onSurface)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 132)
                        .padding(16)
                        .background(EColor.surfaceContainerLowest)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(EColor.outlineVariant))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
            }
        }
    }

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
            TextField("Help with your child's schedule today", text: $draft, axis: .vertical)
                .font(Typography.font(16, weight: .regular))
                // Caps at 4 lines (not 8) — past that it scrolls
                // internally rather than keep growing toward a
                // full-screen textarea.
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? .white : EColor.onSurfaceVariant)
                    .frame(width: 34, height: 34)
                    // A real filled state either way — quiet grey while
                    // empty, not a near-white circle that reads as broken
                    // rather than disabled; solid Evlin green the moment
                    // there's something to send, animating between the
                    // two rather than snapping.
                    .background(canSend ? Brand.greenDeep : EColor.surfaceContainerHigh)
                    .clipShape(Circle())
                    .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
            }
        )
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                .strokeBorder(inputFocused ? EColor.outline : EColor.outlineVariant, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: composerHeight)
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
    }

    // Fully rounded at rest (radius = half the single-line height, a true
    // pill — 26pt at the 52pt rest height, true semicircle ends), easing
    // down to a fixed 22pt as the text wraps to more lines — not scaling
    // radius up *with* height, which is what would produce a stretched
    // capsule instead of an ordinary rounded rect once it's grown past
    // one line.
    private var composerCornerRadius: CGFloat {
        let restHeight: CGFloat = 52
        let maxRadius = restHeight / 2
        let minRadius: CGFloat = 22
        let growthRange: CGFloat = 40
        guard composerHeight > restHeight else { return maxRadius }
        let eased = min(1, (composerHeight - restHeight) / growthRange)
        return maxRadius - (maxRadius - minRadius) * eased
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            // A newly-inserted row — especially a tall card reply like
            // BlockAppCard — hasn't necessarily finished laying out in the
            // same tick its insertion transition starts. Scrolling to the
            // bottom anchor immediately could compute its position before
            // that row has taken up its final height, landing short and
            // leaving the new message half-hidden behind the composer.
            // One tick's deferral lets that layout settle first.
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            let scroll = { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
            if animated {
                withAnimation(.easeOut(duration: 0.25), scroll)
            } else {
                scroll()
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(fromUser: true, text: text))
        draft = ""
        sendToBackend(text)
    }

    // Tapping a welcomeGrid tile — same flow as send(), just sourced from a
    // preset prompt instead of the draft field. A tile that already knows
    // its own target card (Block an app, Add a task, Review progress) shows
    // it instantly — no ambiguity for the model to resolve, the button
    // already says what it means. Everything else (a plain suggestion, or
    // one of the two prompts with no card — "Set a bedtime rule"/"Update
    // the calendar," which used to fake a canned reply) goes to the real
    // backend exactly like a typed message would.
    private func sendSuggestion(_ suggestion: ChatSuggestion) {
        guard !isSending else { return }
        messages.append(ChatMessage(fromUser: true, text: suggestion.prompt))
        if let card = suggestion.card {
            beginResponse(afterSeconds: 0.6) {
                let intro: String
                switch card {
                case .blockApp: intro = "Sure — which app should I block?"
                case .addTask: intro = "I've drafted this from what you asked — check it over and create it:"
                case .blockDuration: intro = "" // never a tile's own card — only reached as a follow-up
                case .reviewCompliance(_, let childName): intro = "Here's where \(childName) stands today:"
                }
                messages.append(ChatMessage(fromUser: false, text: intro, card: card))
            }
        } else if let reply = suggestion.reply {
            respondAfterDelay(with: reply)
        } else {
            sendToBackend(suggestion.prompt)
        }
    }

    // The real backend call — stores the message, grounds the model in
    // this child's actual today's-tasks/rules, and returns either a plain
    // reply or a proposal to open one of the two existing cards (never a
    // direct write; see routers/chat.py). Runs through the same
    // beginResponse-owned Task as every other reply path, so a second
    // message sent mid-flight cancels this one outright instead of racing.
    private func sendToBackend(_ text: String) {
        responseTask?.cancel()
        isSending = true
        responseTask = Task { @MainActor in
            guard let childId = session.activeChildId else { isSending = false; return }
            do {
                let reply = try await APIClient.shared.sendChatMessage(childId: childId, text: text)
                guard !Task.isCancelled else { return }
                isSending = false
                if reply.toolCall != nil {
                    messages.append(ChatMessage(fromUser: false, text: reply.text, card: cardFor(reply)))
                } else {
                    messages.append(ChatMessage(fromUser: false, text: ""))
                    guard let id = messages.last?.id else { return }
                    streamIn(reply.text, into: id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                isSending = false
                messages.append(ChatMessage(fromUser: false, text: "Couldn't reach Evlin's AI. \(error.apiUserMessage)"))
            }
        }
    }

    // Maps a real tool-call response onto one of the two existing cards —
    // shared between a live reply (sendToBackend) and a reloaded history
    // row (loadHistory) so both build the exact same card the same way.
    private func cardFor(_ message: ApiChatMessage) -> ChatCardKind? {
        switch message.toolCall {
        case "open_block_picker": return .blockApp
        case "draft_task":
            let title = message.toolArgs?["title"] ?? ""
            let due = message.toolArgs?["due_hint"] ?? ""
            let repeatsHint = message.toolArgs?["repeats_hint"] ?? ""
            var prompt = "to \(title)"
            if !repeatsHint.isEmpty { prompt += " every \(repeatsHint)" }
            else if !due.isEmpty { prompt += " at \(due)" }
            return .addTask(prompt: prompt)
        default: return nil
        }
    }

    // Real persisted history, replacing an always-empty transcript on
    // every relaunch. Only loads once per appearance (an already-loaded
    // or already-active conversation isn't clobbered by a stale fetch).
    private func loadHistory() async {
        guard messages.isEmpty, let childId = session.activeChildId else { return }
        guard let history = try? await APIClient.shared.fetchChatHistory(childId: childId), !history.isEmpty else { return }
        messages = history.map { m in
            ChatMessage(fromUser: m.role == "user", text: m.text, card: m.toolCall != nil ? cardFor(m) : nil)
        }
    }

    // Apps/categories picked → ask the follow-up question instead of
    // finalizing. No typing delay here: this reads as the same turn
    // continuing, not a new one being considered.
    private func handleSelectTargets(_ names: [String]) {
        guard !names.isEmpty else { return }
        messages.append(ChatMessage(fromUser: false, text: "Got it. And for how long?", card: .blockDuration(apps: names)))
    }

    private func handleBlockDuration(apps: [String], minutes: Int?) {
        // Defensive: BlockDurationCard only ever gets built from a
        // non-empty `names` (handleSelectTargets already guards that), but
        // this closure crosses a card boundary, so it doesn't lean on that
        // holding true forever — an empty list just quietly does nothing
        // rather than producing a message that reads as "Blocked  and ."
        guard !apps.isEmpty else { return }
        let list = apps.count == 1 ? apps[0] : apps.dropLast().joined(separator: ", ") + " and " + (apps.last ?? "")
        let duration = minutes.map { "for \(formatMinutes($0))" } ?? "until you unlock it"
        respondAfterDelay(with: "Blocked \(list) for your child \(duration).")

        // Surfaces the same way a parent-authored Custom rule would — see
        // ScreenProfile's Active Rules. Appended onto the shared Child
        // object itself (not this screen's own state), so it's actually
        // there the next time your child's profile is opened, not just in this
        // chat transcript.
        let blockedChild = FamilyStore.child(session.activeChildId ?? "")
        blockedChild.rules.append(ChildRule(
            id: UUID().uuidString,
            kind: .custom,
            icon: "sf:nosign",
            title: "Block \(list)",
            detail: minutes.map { "Blocked for \(formatMinutes($0))" } ?? "Blocked until unlocked",
            on: true
        ))
        blockedChild.pushRules()
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
    private func handleAddTask(_ title: String, _ whatToDo: String, _ due: String, _ repeats: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty, let childId = session.activeChildId else { return }
        Task {
            do {
                let saved = try await APIClient.shared.createTask(
                    childId: childId, title: trimmedTitle, instructions: whatToDo,
                    recurrence: repeats, category: "Chore", submissionKind: "none"
                )
                await AppSync.shared.syncBackendData()
                let repeatsText = repeats == "none" ? "" : " (\(repeatDisplayLabel(repeats).lowercased()))"
                await MainActor.run {
                    messages.append(ChatMessage(fromUser: false, text: "Added \"\(saved.title)\" for your child\(repeatsText)."))
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(fromUser: false, text: "That task wasn't saved. \(error.apiUserMessage)"))
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(for kind: ChatCardKind) -> some View {
        switch kind {
        case .blockApp:
            BlockAppCard(onSelectTargets: handleSelectTargets)
        case .blockDuration(let apps):
            BlockDurationCard(apps: apps) { minutes in handleBlockDuration(apps: apps, minutes: minutes) }
        case .addTask(let prompt):
            AddTaskCard(initialPrompt: prompt, onCreate: handleAddTask)
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

    // `messages.count` changing (from the empty-message append above) already
    // triggers a scroll-to-bottom; the growing bubble stays in view as it
    // streams since it's the last row, so no per-word re-scroll is needed.
    // Takes over `responseTask` for its own duration, so it's cancelled the
    // same way the delay before it was — a thread switch mid-stream stops
    // writing into a transcript that's no longer showing, rather than a
    // pile of independent timers that fire regardless of what changed.
    private func streamIn(_ fullText: String, into id: UUID) {
        let words = fullText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        responseTask = Task { @MainActor in
            for i in words.indices {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
                messages[idx].text = words[...i].joined(separator: " ")
            }
        }
    }
}

private struct HelpPanel: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Evlin isn't just a chat window — it can act on your family's rules and apps directly. Here's what to try.")
                        .font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)

                    VStack(spacing: 10) {
                        ForEach(capabilities) { c in
                            Card {
                                HStack(alignment: .top, spacing: 12) {
                                    RoundedRectangle(cornerRadius: 12).fill(EColor.primary).frame(width: 38, height: 38)
                                        .overlay(Image(systemName: EIcon.sf(c.icon)).font(.system(size: 17)).foregroundStyle(.white))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.title).font(Typography.font(13.5, weight: .semibold))
                                        Text(c.sub).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("What Evlin can do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Chat history

// KNOWN GAP, not fixed in this pass: the real backend (app.chat_messages,
// routers/chat.py) is one continuous conversation per child, matching how
// the main transcript above already frames it — it has no concept of
// separate named/searchable/renameable threads the way this sidebar's
// model does. loadHistory() (above) loads the real single conversation
// into the main transcript; this sidebar's multi-thread browsing UI still
// runs on chatHistoryMock below. Reconciling "one real conversation" with
// "a ChatGPT-style thread list" is its own real design/backend question
// (e.g. day-bucketing the one conversation into pseudo-threads, or
// building real multi-thread support server-side) — deliberately not
// guessed at here rather than half-wiring something that reads real but
// silently can't rename/delete/search anything for real.
private struct ChatHistoryEntry: Identifiable {
    let id = UUID()
    var title: String
    var time: String
    var section: String // "Today" · "Yesterday" · "Previous 7 Days"
    var transcript: [(fromUser: Bool, text: String)]
}

private let chatHistoryMock: [ChatHistoryEntry] = [
    ChatHistoryEntry(
        title: "Extra time for homework",
        time: "9:41 AM", section: "Today",
        transcript: [
            (true, "Give your child 30 more minutes if his homework's done"),
            (false, "Done — updated your child's controls. I'll unlock the extra 30 minutes automatically once he marks homework complete."),
        ]
    ),
    ChatHistoryEntry(
        title: "Bedtime rule on school nights",
        time: "Yesterday", section: "Yesterday",
        transcript: [
            (true, "Lock all apps at 9pm on school nights"),
            (false, "Set — all apps lock at 9:00 PM Sun–Thu. Want me to add a 15-minute wind-down warning before it kicks in?"),
        ]
    ),
    ChatHistoryEntry(
        title: "TikTok pushback after lock",
        time: "Monday", section: "Previous 7 Days",
        transcript: [
            (true, "your child is really upset that TikTok got locked, what do I say?"),
            (false, "Here's a de-escalation strategy for tonight: acknowledge the frustration first, then offer a fixed choice — a 10-minute walk or a snack break — before revisiting screen time. Kids regulate faster when they feel heard before they're redirected."),
        ]
    ),
    ChatHistoryEntry(
        title: "Weekly usage check-in",
        time: "Monday", section: "Previous 7 Days",
        transcript: [
            (true, "How's your child's screen time trending this week?"),
            (false, "your child's screen time was down 12% from last week — mostly less time in reading apps, so nothing to flag."),
        ]
    ),
]

// A collapsible left sidebar over the chat canvas — the ChatGPT/Claude
// desktop pattern (fixed-width history rail + centered conversation) adapted
// to a phone: an overlay drawer instead of a permanent split view, since
// there's no room to show both panes at once on this width. Keeps Gemini's
// floating rounded row "cards" over a per-row "•••" menu for rename/delete,
// plus a tinted pill on whichever entry is currently loaded into the
// transcript (the "active state" from the desktop reference).
private struct ChatHistorySidebar: View {
    var selectedID: UUID?
    var onSelect: (ChatHistoryEntry) -> Void
    var onNewChat: () -> Void
    var onClose: () -> Void

    @State private var entries = chatHistoryMock
    @State private var query = ""
    @State private var renamingEntry: ChatHistoryEntry?
    @State private var renameText = ""
    // Lets a finger drag the whole panel toward its exit edge (matching the
    // .move(edge: .leading) transition it entered with) instead of the x/
    // sidebar button being the only way out — dragged part-way then
    // released short of the threshold springs back rather than committing.
    @State private var dragOffset: CGFloat = 0

    private var filtered: [ChatHistoryEntry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var sections: [String] {
        var seen = Set<String>()
        return filtered.map(\.section).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField

            if filtered.isEmpty {
                Spacer()
                Text("No conversations found")
                    .font(Typography.font(15, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if query.isEmpty {
                            newChatRow
                        }
                        ForEach(sections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.uppercased())
                                    .font(Typography.font(12.5, weight: .bold))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                                    .tracking(0.4)
                                    .padding(.horizontal, 8)
                                VStack(spacing: 3) {
                                    ForEach(filtered.filter { $0.section == section }) { entry in
                                        row(entry)
                                    }
                                }
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
        .alert("Rename Chat", isPresented: Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingEntry = nil }
            Button("Save") {
                if let id = renamingEntry?.id, let i = entries.firstIndex(where: { $0.id == id }) {
                    entries[i].title = renameText
                }
                renamingEntry = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close chat history")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(EColor.onSurfaceVariant)
            TextField("Search conversations", text: $query)
                .font(Typography.font(15, weight: .regular))
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
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: ChatHistoryEntry) -> some View {
        let isActive = entry.id == selectedID
        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(Typography.font(16, weight: isActive ? .bold : .medium))
                        .foregroundStyle(EColor.onSurface)
                        .lineLimit(1)
                    Text(entry.time)
                        .font(Typography.font(13, weight: .regular))
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
                        entries.removeAll { $0.id == entry.id }
                        if selectedID == entry.id { onNewChat() }
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
        .buttonStyle(.plain)
    }
}
