import SwiftUI

struct ScreenTabletHome: View {
    @Binding var tasks: [KidTask]
    var onSwitchMode: () -> Void
    // Owned by TabletRootView (which presents the shared TaskDetailView
    // cover) — the Ring tab needs to open the same detail flow for the
    // same shared `tasks` array, so this can't be this screen's own local
    // @State any more.
    var onSelectTask: (KidTask) -> Void
    // Settings/Parent Controls used to be its own bottom tab — its only
    // content was this one request, so it's a toolbar icon here instead,
    // out of the kid's main navigation entirely (see TabletRootView).
    @State private var showSettings = false
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
    private var nextTaskId: String? { tasks.first { !$0.done }?.id }
    private var doneCount: Int { tasks.filter(\.done).count }

    private func accent(for taskId: String) -> Color {
        let idx = tasks.firstIndex { $0.iconTaskId == taskId } ?? 0
        return KidAccent.color(for: idx)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Good \(greeting)").font(Typography.font(greetingFont, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                    Text("Hey \(childName)! 👋").font(Typography.display(nameFont, weight: .heavy)).foregroundStyle(KidTheme.ink)

                    HStack {
                        Text("Today").font(Typography.display(sectionTitleFont, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Spacer()
                        Text("\(doneCount) of \(tasks.count) done")
                            .font(Typography.font(sectionCountFont, weight: .heavy))
                            .foregroundStyle(doneCount == tasks.count ? KidTheme.greenDeep : KidTheme.inkSoft)
                    }
                    .padding(.top, 22).padding(.bottom, 13)

                    VStack(spacing: taskCardSpacing) {
                        ForEach($tasks) { $task in
                            Button { onSelectTask(task) } label: {
                                taskCard(task, isNext: task.id == nextTaskId)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .kidContentColumn(kid.contentMaxWidth)
            }
            .background(KidTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(KidTheme.inkSoft)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ScreenTabletSettings(onSwitchMode: onSwitchMode)
        }
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

    private func taskCard(_ task: KidTask, isNext: Bool) -> some View {
        let awaitingBypass = task.bypassRequested && !task.done
        let needsRedo = task.redoRequested
        // A task waiting on a parent's review looks exactly like a plain
        // finished one to the kid — no separate "still pending" state, no
        // hourglass, no "waiting for your parent" label. Whether it's been
        // approved yet is the parent's business, not something to make the
        // kid sit and watch for. Redo is the one exception: it puts the
        // task back in "to do" territory visually (not struck through,
        // full opacity) — the banner below is what explains why, rather
        // than the row just looking like nothing ever happened.
        let doneLook = task.done && !needsRedo

        let chipColor = needsRedo ? redoOrangeTint : (awaitingBypass ? KidTheme.lavender : KidTheme.cream)
        let chipIconColor = needsRedo ? redoOrangeText : (awaitingBypass ? KidTheme.lavenderText : KidTheme.greenDeep)
        let chipIcon = awaitingBypass ? "hand.raised.fill" : TabletData.guessedIcon(forTitle: task.title)
        let ringColor = doneLook ? KidTheme.green : (needsRedo ? redoOrangeText : (awaitingBypass ? KidTheme.lavenderText : (isNext ? KidTheme.green : Color(hex: "D5DED8"))))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(chipColor)
                    .frame(width: taskIconSize, height: taskIconSize)
                    .overlay(
                        Image(systemName: chipIcon)
                            .font(.system(size: taskIconFont))
                            .foregroundStyle(chipIconColor)
                            .opacity(doneLook ? 0.5 : 1)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    if isNext && !task.done && !awaitingBypass && !needsRedo {
                        Text("NEXT").font(Typography.font(10.5, weight: .bold)).tracking(0.6)
                            .foregroundStyle(KidTheme.greenDeep)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.white).clipShape(Capsule())
                    }
                    Text(task.title)
                        .font(Typography.font(taskTitleFont, weight: .semibold))
                        .foregroundStyle(doneLook ? KidTheme.inkSoft : KidTheme.ink)
                        .strikethrough(doneLook, color: Color(hex: "B5C8BC"))
                    if needsRedo {
                        Label("Parent asked for a redo", systemImage: "arrow.counterclockwise")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(redoOrangeText)
                    } else if awaitingBypass {
                        Label("Waiting on a parent", systemImage: "hand.raised.fill")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.lavenderText)
                    } else if !task.done, let due = task.due {
                        Label("Due \(due)", systemImage: "clock")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                    }
                }
                Spacer()
                Circle()
                    .fill(doneLook ? KidTheme.green : .white)
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
            if needsRedo, let note = task.redoNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(redoOrangeText).frame(width: 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note)
                            .font(Typography.font(taskMetaFont, weight: .medium))
                            .foregroundStyle(KidTheme.ink)
                        if task.redoHasVoiceNote {
                            Label("Voice note", systemImage: "waveform")
                                .font(Typography.font(taskMetaFont - 1, weight: .bold))
                                .foregroundStyle(redoOrangeText)
                        }
                    }
                }
            }
        }
        .padding(taskCardPadding)
        .background(needsRedo ? redoOrangeTint.opacity(0.55) : (awaitingBypass ? KidTheme.lavender.opacity(0.5) : (isNext && !task.done ? KidTheme.greenTint : KidTheme.cream)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(needsRedo ? redoOrangeText.opacity(0.4) : (awaitingBypass ? KidTheme.lavenderText : (isNext && !task.done ? KidTheme.green : KidTheme.line))))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .opacity(doneLook ? 0.65 : 1)
    }
}
