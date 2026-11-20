import SwiftUI

struct ScreenTabletHome: View {
    @Binding var tasks: [KidTask]
    var onSwitchMode: () -> Void
    // Owned by TabletRootView (which presents the shared TaskDetailView
    // cover) — the Ring tab needs to open the same detail flow for the
    // same shared `tasks` array, so this can't be this screen's own local
    // @State any more.
    var onSelectTask: (KidTask) -> Void
    // The play-time bar, above this tab's own navigation (owned by
    // TabletRootView, which has the numbers). Drawn here rather than above
    // the whole tab view: there, shown on this tab only, it changed the tab
    // view's height on every switch, and the other tabs kept a shorter
    // frame, so the bottom of their screens (the calendar's +) didn't
    // answer taps until a sheet made the layout run again.
    var topBar: AnyView = AnyView(EmptyView())
    // Settings/Parent Controls used to be its own bottom tab — its only
    // content was this one request, so it's a toolbar icon here instead,
    // out of the kid's main navigation entirely (see TabletRootView).
    @State private var showSettings = false
    /// The right code typed: the settings, until the sheet closes. The next
    /// tap on the gear asks again.
    @State private var settingsOpen = false
    @MainActor private static var demoSettingsShown = false
    @Environment(SessionManager.self) private var session
    // The name the parent sees for this child (synced from the backend).
    private var childName: String {
        _ = SyncState.shared.version
        let kids = FamilyStore.children
        return kids.first(where: { $0.id == session.activeChildId })?.name ?? kids.first?.name ?? "there"
    }
    // This screen used to render identically on iPhone and iPad — same
    // fixed sizing just stretched across whatever width it landed on, which
    // read as an oversized phone layout with a lot of dead margin rather
    // than an iPad-appropriate one. `kid.isRegular` (iPad, and iPhone
    // landscape on the larger Plus/Max/Pro Max models) caps the content
    // column's width instead of letting it run edge-to-edge, and scales up
    // the task cards specifically — bigger tap targets and text read better
    // for a kid audience regardless of device, so the phone gets a smaller
    // bump too rather than staying untouched. See KidAdaptive.swift.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }
    // The first pass at this only bumped these a few points over the phone
    // values, which on an actual iPad still read as a stretched phone list
    // floating in a wide margin rather than a layout actually sized for
    // the bigger canvas — these are now a real step up, not a nudge.
    private var taskIconSize: CGFloat { kid.of(54, 72) }
    private var taskIconFont: CGFloat { kid.of(22, 28) }
    private var taskTitleFont: CGFloat { kid.of(17, 21) }
    private var taskMetaFont: CGFloat { kid.of(13, 15) }
    private var taskCheckSize: CGFloat { kid.of(30, 38) }
    private var taskCardPadding: CGFloat { kid.of(16, 22) }
    private var taskCardSpacing: CGFloat { kid.of(12, 18) }
    private var greetingFont: CGFloat { kid.of(14, 16) }
    private var nameFont: CGFloat { kid.of(30, 36) }
    private var sectionTitleFont: CGFloat { kid.of(20, 24) }
    private var sectionCountFont: CGFloat { kid.of(13.5, 15) }
    // Done means approved (or a skip said yes to), the same count the
    // parent's phone shows. A task sent in and waiting isn't done yet.
    private var doneCount: Int { tasks.filter(\.approved).count }

    private func accent(for taskId: String) -> Color {
        let idx = tasks.firstIndex { $0.iconTaskId == taskId } ?? 0
        return KidAccent.color(for: idx)
    }

    var body: some View {
        Group {
            if kid.isRegular { regularBody } else { compactBody }
        }
        .task {
            guard DemoMode.kidParentGate || DemoMode.kidParentSettings else { return }
            try? await Task.sleep(for: .seconds(1))
            showSettings = true
        }
        // The gear: straight to "Parents only" and the screen time access
        // code from the parent's phone (2026-11-19, the user's call; a
        // Parent Controls list with one row in front of it before).
        // The right code opens this device's settings (2026-11-19, the
        // user's call), every time: closed, the gear asks again.
        .sheet(isPresented: $showSettings, onDismiss: { settingsOpen = false }) {
            Group {
                if settingsOpen {
                    KidParentSettings(onDone: { showSettings = false })
                        .transition(.opacity)
                } else {
                    ParentAccessGate(onUnlocked: { withAnimation(.easeInOut(duration: 0.25)) { settingsOpen = true } },
                                     onCancel: { showSettings = false })
                        .transition(.opacity)
                        // Demo: `-EvlinKidParentSettings`, as if the code was typed, once.
                        .task {
                            guard DemoMode.kidParentSettings, !Self.demoSettingsShown else { return }
                            Self.demoSettingsShown = true
                            try? await Task.sleep(for: .seconds(0.8))
                            withAnimation(.easeInOut(duration: 0.25)) { settingsOpen = true }
                        }
                }
            }
            .presentationDragIndicator(.visible)
        }
    }

    // iPad, either way up: one scrolling page using the whole width, the
    // gear beside the greeting, and the tasks as a grid that gets another
    // column when there's room (two upright, three sideways).
    private var regularBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Good \(greeting)").font(Typography.font(greetingFont, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                        Text("Hey \(childName)! 👋").font(Typography.display(nameFont, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(KidTheme.inkSoft)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(KidTheme.cream))
                            .overlay(Circle().strokeBorder(KidTheme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }

                topBar.kidTourSpot(.playTime).padding(.top, 20)

                HStack {
                    Text("Today").font(Typography.display(sectionTitleFont, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    Spacer()
                    Text("\(doneCount) of \(tasks.count) done")
                        .font(Typography.font(sectionCountFont, weight: .heavy))
                        .foregroundStyle(doneCount == tasks.count ? KidTheme.greenDeep : KidTheme.inkSoft)
                }
                .modifier(KidTourFirst(on: tasks.isEmpty, spot: .task))
                .padding(.top, 28).padding(.bottom, 14)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: taskCardSpacing, alignment: .top)],
                          spacing: taskCardSpacing) {
                    ForEach(tasks) { task in
                        Button { onSelectTask(task) } label: {
                            taskCard(task)
                        }
                        .buttonStyle(.plain)
                        .modifier(KidTourFirst(on: task.id == tasks.first?.id, spot: .task))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(EPaperBackground())
    }

    // A phone: the iPad's page in one column (2026-11-12): the greeting with
    // the gear beside it, the play-time card, then Today's tasks, all on the
    // page. Before, the card sat above the page (on black by night) over a
    // navigation bar holding only the gear, which left an empty band.
    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Good \(greeting)").font(Typography.font(greetingFont, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                        Text("Hey \(childName)! 👋").font(Typography.display(nameFont, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(KidTheme.inkSoft)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(KidTheme.cream))
                            .overlay(Circle().strokeBorder(KidTheme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                // Its own side padding (22) and a gap over it.
                topBar.kidTourSpot(.playTime)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Today").font(Typography.display(sectionTitleFont, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Spacer()
                        Text("\(doneCount) of \(tasks.count) done")
                            .font(Typography.font(sectionCountFont, weight: .heavy))
                            .foregroundStyle(doneCount == tasks.count ? KidTheme.greenDeep : KidTheme.inkSoft)
                    }
                    .modifier(KidTourFirst(on: tasks.isEmpty, spot: .task))
                    .padding(.top, 22).padding(.bottom, 13)

                    VStack(spacing: taskCardSpacing) {
                        ForEach($tasks) { $task in
                            Button { onSelectTask(task) } label: {
                                taskCard(task)
                            }
                            .buttonStyle(.plain)
                            .modifier(KidTourFirst(on: task.id == tasks.first?.id, spot: .task))
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
            .padding(.bottom, 100)
        }
        .background(EPaperBackground())
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "morning" : h < 18 ? "afternoon" : "evening"
    }

    // A parent asking for a redo instead of approving — "almost there, one
    // more pass," not an alarm. A genuinely bright, warm orange (close to
    // KidAccent's own) instead of the muted rust/brown this used to be,
    // which read as too serious/adult for a kid audience — kept just a
    // shade deeper than KidAccent's brightest orange so the small label
    // text stays legible on a light background.
    private let redoOrangeTint = Color(hex: "FFEDD5")
    private let redoOrangeText = Color(hex: "EA580C")
    // The parent's "waiting for you" colour.
    private let waitingColor = HomeStyle.waiting

    // No NEXT card (2026-11-17, the user's call: removed; the first task not
    // done was a green card with a NEXT tag). The approved tick is the
    // kid's button green at full strength (the same day: the mascot green
    // faded with the card read washed out).
    private func taskCard(_ task: KidTask) -> some View {
        let awaitingBypass = task.bypassRequested && !task.done
        // The kid's ask to skip, answered: yes reads as "skipped", not as a
        // finished task; no reads as "still on", with the parent's words.
        let skipped = task.bypassRequested && task.approved
        let skipKept = !task.done && task.skipDeclinedNote != nil
        let needsRedo = task.redoRequested
        // Sent in, not checked yet: keep its ring orange rather than making
        // it look finished. Only an approval (or a skip said yes to) gets
        // the green tick.
        let waitingReview = task.pendingApproval && !task.bypassRequested && !needsRedo
        let doneLook = task.approved && !needsRedo

        let chipColor = needsRedo ? redoOrangeTint : (awaitingBypass ? KidTheme.lavender : KidTheme.cream)
        let chipEmoji = awaitingBypass ? "✋" : task.emoji
        let ringColor = doneLook ? KidTheme.paperButton : (waitingReview ? waitingColor : (needsRedo ? redoOrangeText : (awaitingBypass ? KidTheme.lavenderText : Color(hex: "D5DED8"))))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(chipColor)
                    .frame(width: taskIconSize, height: taskIconSize)
                    .overlay(
                        Text(chipEmoji)
                            .font(.system(size: taskIconFont * 1.3))
                            .opacity(doneLook ? 0.45 : 1)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(Typography.font(taskTitleFont, weight: .semibold))
                        .foregroundStyle(doneLook ? KidTheme.inkSoft : KidTheme.ink)
                        .strikethrough(doneLook, color: Color(hex: "B5C8BC"))
                        .opacity(doneLook ? 0.65 : 1)
                    if needsRedo {
                        Label("Parent asked for a redo", systemImage: "arrow.counterclockwise")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(redoOrangeText)
                    } else if awaitingBypass {
                        Label("Waiting on a parent", systemImage: "hand.raised.fill")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.lavenderText)
                    } else if skipped {
                        Label("Skipped for today", systemImage: "hand.thumbsup.fill")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.lavenderText)
                    } else if skipKept {
                        Label("Still on for today", systemImage: "hand.raised.fill")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.lavenderText)
                    } else if !task.done, let due = task.due {
                        Label("Due \(due)", systemImage: "clock")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                    }
                }
                Spacer()
                Circle()
                    .fill(doneLook ? KidTheme.paperButton : KidTheme.cream)
                    .frame(width: taskCheckSize, height: taskCheckSize)
                    .overlay(Circle().strokeBorder(ringColor, lineWidth: 2))
                    .overlay {
                        if doneLook {
                            Image(systemName: "checkmark").font(.system(size: taskCheckSize * 0.46, weight: .bold)).foregroundStyle(.white)
                        }
                    }
            }

            // A colored accent bar instead of its own nested box — the
            // note reads as the parent's own words sitting inside this
            // card, not as a separate sticker glued underneath it (the
            // card's own background is tinted the same orange below).
            if skipKept, let note = task.skipDeclinedNote {
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(KidTheme.lavenderText).frame(width: 3)
                    Text(note)
                        .font(Typography.font(taskMetaFont, weight: .medium))
                        .foregroundStyle(KidTheme.ink)
                }
            }

            if needsRedo, let note = task.redoNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(redoOrangeText).frame(width: 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note)
                            .font(Typography.font(taskMetaFont, weight: .medium))
                            .foregroundStyle(KidTheme.ink)
                    }
                }
            }
        }
        .padding(taskCardPadding)
        .background(needsRedo ? redoOrangeTint.opacity(0.55) : (awaitingBypass ? KidTheme.lavender.opacity(0.5) : KidTheme.cream))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(needsRedo ? redoOrangeText.opacity(0.4) : (awaitingBypass ? KidTheme.lavenderText : KidTheme.line)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
