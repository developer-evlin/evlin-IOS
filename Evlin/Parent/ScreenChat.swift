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
    case addTask
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

// Bubbles are capped so a long unbroken token (a URL, a hash, code with no
// spaces) wraps inside the bubble instead of forcing the whole HStack wider
// than the screen. `fixedSize(horizontal:false,...)` is the actual fix —
// without it SwiftUI's Text can request its ideal single-line width even
// inside a maxWidth frame, which is the classic cause of chat rows
// overflowing horizontally.
private let bubbleMaxWidth: CGFloat = 300

// Renders a message body, splitting out ```-fenced code blocks into their
// own monospaced, horizontally-scrollable strip so a long code line scrolls
// sideways within its own box instead of stretching the chat bubble (or the
// screen) wide.
private struct MessageContent: View {
    var text: String

    var body: some View {
        let parts = text.components(separatedBy: "```")
        if parts.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        EmptyView()
                    } else if i % 2 == 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(trimmed)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text(trimmed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Three dots that bounce in a staggered loop while a response is pending.
private struct TypingIndicator: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(EColor.onSurfaceVariant)
                    .frame(width: 6, height: 6)
                    .offset(y: bounce ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
        .onAppear { bounce = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evlin is typing")
    }
}

// MARK: - Inline chat cards

// Small stand-in catalog since there's no real installed-app inventory to
// query — bundle IDs are shown because that's specifically what was asked
// for, matching how Evlin-iOS's own disambiguation cards (AppControlCard's
// app_store_disambiguation) label each candidate.
private struct MockApp: Identifiable {
    let id = UUID()
    var name: String
    var bundleID: String
    var icon: String
    var color: Color
}

private let mockAppCatalog: [MockApp] = [
    MockApp(name: "TikTok", bundleID: "com.zhiliaoapp.musically", icon: "music.note", color: .black),
    MockApp(name: "Instagram", bundleID: "com.burbn.instagram", icon: "camera.fill", color: Color(hex: "E1306C")),
    MockApp(name: "YouTube", bundleID: "com.google.ios.youtube", icon: "play.rectangle.fill", color: .red),
    MockApp(name: "Roblox", bundleID: "com.roblox.robloxmobile", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockApp(name: "Snapchat", bundleID: "com.toyopagroup.picaboo", icon: "camera.fill", color: Color(hex: "FFFC00")),
    MockApp(name: "Discord", bundleID: "com.hammerandchisel.discord", icon: "bubble.left.and.bubble.right.fill", color: Color(hex: "5865F2")),
    MockApp(name: "Messages", bundleID: "com.apple.MobileSMS", icon: "message.fill", color: .green),
    MockApp(name: "Safari", bundleID: "com.apple.mobilesafari", icon: "safari.fill", color: .blue),
]

// Mirrors LockListManagerView's real Apps/Categories split (Views/Settings/
// LockListManagerView.swift) — blocking a whole category, not just named
// apps, is a real option there.
private struct MockCategory: Identifiable {
    let id = UUID()
    var name: String
    var icon: String
    var color: Color
}

private let mockCategoryCatalog: [MockCategory] = [
    MockCategory(name: "Social Media", icon: "person.2.fill", color: Color(hex: "E1306C")),
    MockCategory(name: "Games", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockCategory(name: "Entertainment", icon: "play.rectangle.fill", color: .red),
    MockCategory(name: "Messaging", icon: "message.fill", color: .green),
]

private enum BlockTargetTab: String, CaseIterable { case apps = "Apps", categories = "Categories" }

// Row shape (icon, name, subtitle, trailing checkbox) is closest to
// Evlin-iOS's U1Card (unlock_picker), adapted for picking targets to block
// instead of unlock. The Apps/Categories tab split, search field, and
// bundle-ID subtitle mirror LockListManagerView's real section layout —
// production hides bundle IDs behind a separate manual-naming step (Apple's
// FamilyActivityPicker doesn't expose them), which doesn't apply here since
// this catalog is mock data with real names already attached.
private struct BlockAppCard: View {
    // Just the target pick — duration is its own follow-up turn
    // (BlockDurationCard below), not a section tacked onto this same card.
    var onSelectTargets: ([String]) -> Void

    @State private var tab: BlockTargetTab = .apps
    @State private var query = ""
    @State private var selectedApps: Set<UUID> = []
    @State private var selectedCategories: Set<UUID> = []
    @State private var submitted = false

    private var filteredApps: [MockApp] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return mockAppCatalog }
        return mockAppCatalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredCategories: [MockCategory] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return mockCategoryCatalog }
        return mockCategoryCatalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var totalSelected: Int { selectedApps.count + selectedCategories.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(EColor.danger)
                Text("Block an app").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }

            HStack(spacing: 6) {
                ForEach(BlockTargetTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(Typography.font(12.5, weight: .semibold))
                            .foregroundStyle(tab == t ? .white : EColor.onSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(tab == t ? EColor.danger : EColor.surfaceContainerHigh)
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
                VStack(spacing: 4) {
                    ForEach(filteredApps) { app in
                        Button { toggleApp(app) } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(app.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(Image(systemName: app.icon).font(.system(size: 14)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(Typography.font(13.5, weight: .semibold)).foregroundStyle(EColor.onSurface)
                                    Text(app.bundleID).font(Typography.font(10.5, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selectedApps.contains(app.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17))
                                    .foregroundStyle(selectedApps.contains(app.id) ? EColor.danger : EColor.outlineVariant)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(selectedApps.contains(app.id) ? EColor.danger.opacity(0.07) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(filteredCategories) { cat in
                        Button { toggleCategory(cat) } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(cat.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(Image(systemName: cat.icon).font(.system(size: 14)).foregroundStyle(.white))
                                Text(cat.name).font(Typography.font(13.5, weight: .semibold)).foregroundStyle(EColor.onSurface)
                                Spacer(minLength: 8)
                                Image(systemName: selectedCategories.contains(cat.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17))
                                    .foregroundStyle(selectedCategories.contains(cat.id) ? EColor.danger : EColor.outlineVariant)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(selectedCategories.contains(cat.id) ? EColor.danger.opacity(0.07) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                let appNames = mockAppCatalog.filter { selectedApps.contains($0.id) }.map(\.name)
                let categoryNames = mockCategoryCatalog.filter { selectedCategories.contains($0.id) }.map(\.name)
                submitted = true
                onSelectTargets(appNames + categoryNames)
            } label: {
                Text(totalSelected == 0 ? "Select apps or categories to block" : "Block \(totalSelected) selected")
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

    private func toggleApp(_ app: MockApp) {
        guard !submitted else { return }
        if selectedApps.contains(app.id) { selectedApps.remove(app.id) } else { selectedApps.insert(app.id) }
    }

    private func toggleCategory(_ cat: MockCategory) {
        guard !submitted else { return }
        if selectedCategories.contains(cat.id) { selectedCategories.remove(cat.id) } else { selectedCategories.insert(cat.id) }
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

// Matches Evlin-iOS's real AddTaskForm (Views/Profile/AddBottomSheet.swift)
// field-for-field: Title, Category (pill selector over the app's actual
// TaskCategory-equivalent set), What to do, and Due as a plain free-text
// field — not a DatePicker. Their form doesn't parse or validate that text
// at all, so this doesn't either; it's stored as-is, same as production.
private enum TaskCategory: String, CaseIterable {
    case chore = "Chore", homework = "Homework", reading = "Reading", routine = "Routine"
}

private struct AddTaskCard: View {
    var onCreate: (String, TaskCategory, String, String) -> Void

    @State private var title = ""
    @State private var category: TaskCategory = .chore
    @State private var whatToDo = ""
    @State private var due = ""
    @State private var submitted = false

    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !submitted }

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

            VStack(alignment: .leading, spacing: 5) {
                Text("CATEGORY")
                    .font(Typography.font(10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(EColor.onSurfaceVariant)
                FlowChips {
                    ForEach(TaskCategory.allCases, id: \.self) { c in
                        DotChip(label: c.rawValue, color: nil, selected: category == c) { category = c }
                    }
                }
            }

            cardField(label: "What to do") {
                TextField("Instructions…", text: $whatToDo, axis: .vertical)
                    .font(Typography.font(13.5, weight: .regular))
                    .lineLimit(2...4)
            }

            cardField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM", text: $due)
                    .font(Typography.font(13.5, weight: .regular))
            }

            Button {
                submitted = true
                onCreate(title, category, whatToDo, due)
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
}

private let welcomeSuggestions: [ChatSuggestion] = [
    ChatSuggestion(icon: "apps", title: "Lock TikTok for 30 min", prompt: "Lock TikTok for Liam for 30 minutes"),
    ChatSuggestion(icon: "gavel", title: "Set a bedtime rule", prompt: "Lock all apps at 9pm on school nights"),
    ChatSuggestion(icon: "sf:checklist", title: "Add a task", prompt: "Add a task for Liam", card: .addTask),
    ChatSuggestion(icon: "sf:nosign", title: "Block an app", prompt: "Block an app for Liam", card: .blockApp),
]

struct ScreenChat: View {
    // No canned "I'm Evlin" bubble seeded in — the empty state's welcomeGrid
    // already carries that greeting, so the transcript itself only ever
    // holds real exchanges the user actually sent/received.
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
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
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(messages) { m in
                                    HStack {
                                        if m.fromUser { Spacer(minLength: 40) }
                                        HStack(alignment: .top, spacing: 10) {
                                            if !m.fromUser {
                                                RoundedRectangle(cornerRadius: 9).fill(EColor.primary).frame(width: 28, height: 28)
                                                    .overlay(Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(Color(hex: "8CE6A8")))
                                            }
                                            if let card = m.card {
                                                // The intro line + the card are one message, one
                                                // avatar — matches how a real card reply reads as a
                                                // single turn, not two separate bubbles.
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text(m.text)
                                                        .font(Typography.font(13, weight: .medium))
                                                        .foregroundStyle(EColor.onSurface)
                                                    cardView(for: card)
                                                }
                                            } else {
                                                MessageContent(text: m.text)
                                                    .font(Typography.font(13, weight: .medium))
                                                    .foregroundStyle(m.fromUser ? .white : EColor.onSurface)
                                                    .padding(12)
                                                    .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                                                    .background(m.fromUser ? EColor.primary : EColor.surfaceContainerLowest)
                                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(m.fromUser ? .clear : EColor.outlineVariant))
                                                    // Gemini/ChatGPT-style streaming reveal (see respondAfterDelay) —
                                                    // as words get appended to `m.text`, the bubble smoothly grows
                                                    // into its new size instead of snapping, so new text feels like
                                                    // it's floating/settling into place.
                                                    .animation(.easeOut(duration: 0.16), value: m.text)
                                            }
                                        }
                                        if !m.fromUser { Spacer(minLength: 40) }
                                    }
                                    .id(m.id)
                                    .transition(messageTransition)
                                }

                                if isSending {
                                    HStack {
                                        HStack(alignment: .top, spacing: 10) {
                                            RoundedRectangle(cornerRadius: 9).fill(EColor.primary).frame(width: 28, height: 28)
                                                .overlay(Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(Color(hex: "8CE6A8")))
                                            TypingIndicator()
                                        }
                                        Spacer(minLength: 40)
                                    }
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
                .background(EColor.surface)
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
                .onPreferenceChange(ChatScrollOffsetKey.self) { newOffset in
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
                        selectedEntryID = entry.id
                        messages = entry.transcript.map { ChatMessage(fromUser: $0.fromUser, text: $0.text) }
                        withAnimation(.easeOut(duration: 0.22)) { showHistory = false }
                    },
                    onNewChat: {
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

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Evlin…", text: $draft, axis: .vertical)
                .font(Typography.font(14, weight: .regular))
                .lineLimit(1...4) // grows for a pasted paragraph, caps so the bar can't eat the whole screen
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(EColor.surfaceContainerLowest)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(EColor.outlineVariant))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let scroll = { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.25), scroll)
        } else {
            scroll()
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(fromUser: true, text: text))
        draft = ""
        respondAfterDelay(with: "Got it — I'll take care of that.")
    }

    // Tapping a welcomeGrid tile — same flow as send(), just sourced from a
    // preset prompt instead of the draft field. A tile carrying a card kind
    // shows that card instead of the plain streamed-text reply.
    private func sendSuggestion(_ suggestion: ChatSuggestion) {
        guard !isSending else { return }
        messages.append(ChatMessage(fromUser: true, text: suggestion.prompt))
        if let card = suggestion.card {
            isSending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isSending = false
                let intro: String
                switch card {
                case .blockApp: intro = "Sure — which app should I block?"
                case .addTask: intro = "Sure — what's the task?"
                case .blockDuration: intro = "" // never a tile's own card — only reached as a follow-up
                }
                messages.append(ChatMessage(fromUser: false, text: intro, card: card))
            }
        } else {
            respondAfterDelay(with: "Got it — I'll take care of that.")
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
        let list = apps.count == 1 ? apps[0] : apps.dropLast().joined(separator: ", ") + " and " + (apps.last ?? "")
        let duration = minutes.map { "for \(formatMinutes($0))" } ?? "until you unlock it"
        respondAfterDelay(with: "Blocked \(list) for Liam \(duration).")
    }

    private func handleAddTask(_ title: String, _ category: TaskCategory, _ whatToDo: String, _ due: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let dueTrimmed = due.trimmingCharacters(in: .whitespaces)
        let dueText = dueTrimmed.isEmpty ? "" : ", due \(dueTrimmed)"
        respondAfterDelay(with: "Added \"\(title)\" (\(category.rawValue)) for Liam\(dueText).")
    }

    @ViewBuilder
    private func cardView(for kind: ChatCardKind) -> some View {
        switch kind {
        case .blockApp:
            BlockAppCard(onSelectTargets: handleSelectTargets)
        case .blockDuration(let apps):
            BlockDurationCard(apps: apps) { minutes in handleBlockDuration(apps: apps, minutes: minutes) }
        case .addTask:
            AddTaskCard(onCreate: handleAddTask)
        }
    }

    // Stand-in for a real backend call: after the typing-dots delay, appends
    // one empty assistant message, then streams words into it (Gemini/
    // ChatGPT-style) rather than popping the whole reply in at once. A real
    // backend integration would replace the word-splitting/timer below with
    // appending each chunk as it arrives over the wire.
    private func respondAfterDelay(with text: String) {
        isSending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            isSending = false
            messages.append(ChatMessage(fromUser: false, text: ""))
            guard let id = messages.last?.id else { return }
            streamIn(text, into: id)
        }
    }

    // `messages.count` changing (from the empty-message append above) already
    // triggers a scroll-to-bottom; the growing bubble stays in view as it
    // streams since it's the last row, so no per-word re-scroll is needed.
    private func streamIn(_ fullText: String, into id: UUID) {
        let words = fullText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for i in words.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
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
            (true, "Give Liam 30 more minutes if his homework's done"),
            (false, "Done — updated Liam's controls. I'll unlock the extra 30 minutes automatically once he marks homework complete."),
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
            (true, "Liam is really upset that TikTok got locked, what do I say?"),
            (false, "Here's a de-escalation strategy for tonight: acknowledge the frustration first, then offer a fixed choice — a 10-minute walk or a snack break — before revisiting screen time. Kids regulate faster when they feel heard before they're redirected."),
        ]
    ),
    ChatHistoryEntry(
        title: "Weekly usage check-in",
        time: "Monday", section: "Previous 7 Days",
        transcript: [
            (true, "How's everyone's screen time trending this week?"),
            (false, "Screen time was down 12% from last week across the family. Maya's the only one trending up — mostly reading apps, so nothing to flag."),
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
                    .font(Typography.font(13, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if query.isEmpty {
                            newChatRow
                        }
                        ForEach(sections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.uppercased())
                                    .font(Typography.font(11, weight: .bold))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                                    .tracking(0.4)
                                    .padding(.horizontal, 6)
                                VStack(spacing: 2) {
                                    ForEach(filtered.filter { $0.section == section }) { entry in
                                        row(entry)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
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
                .font(Typography.font(17, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close chat history")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(EColor.onSurfaceVariant)
            TextField("Search conversations", text: $query)
                .font(Typography.font(13, weight: .regular))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(EColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var newChatRow: some View {
        Button(action: onNewChat) {
            HStack(spacing: 12) {
                Circle()
                    .fill(EColor.primaryContainer)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(EColor.primary)
                    )
                Text("New chat")
                    .font(Typography.font(14, weight: .semibold))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: ChatHistoryEntry) -> some View {
        let isActive = entry.id == selectedID
        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typography.font(13.5, weight: isActive ? .bold : .medium))
                        .foregroundStyle(EColor.onSurface)
                        .lineLimit(1)
                    Text(entry.time)
                        .font(Typography.font(11, weight: .regular))
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            // The tinted pill is the only "which thread am I looking at"
            // signal in a drawer this narrow — mirrors the selected-row
            // highlight in ChatGPT/Claude's sidebar.
            .background(isActive ? EColor.primaryContainer : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
