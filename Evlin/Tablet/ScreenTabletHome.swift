import SwiftUI

struct ScreenTabletHome: View {
    @Binding var tasks: [KidTask]
    var onSwitchMode: () -> Void
    @State private var selectedTask: KidTask?
    // Settings/Parent Controls used to be its own bottom tab — its only
    // content was this one request, so it's a toolbar icon here instead,
    // out of the kid's main navigation entirely (see TabletRootView).
    @State private var showSettings = false
    // This screen used to render identically on iPhone and iPad — same
    // fixed sizing just stretched across whatever width it landed on, which
    // read as an oversized phone layout with a lot of dead margin rather
    // than an iPad-appropriate one. `isRegular` (iPad, and iPhone landscape
    // on the larger Plus/Max/Pro Max models) caps the content column's
    // width instead of letting it run edge-to-edge, and scales up the task
    // cards specifically — bigger tap targets and text read better for a
    // kid audience regardless of device, so the phone gets a smaller bump
    // too rather than staying untouched.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }
    // The first pass at this only bumped these a few points over the phone
    // values, which on an actual iPad still read as a stretched phone list
    // floating in a wide margin rather than a layout actually sized for
    // the bigger canvas — these are now a real step up, not a nudge.
    private var contentMaxWidth: CGFloat? { isRegular ? 760 : nil }
    private var taskIconSize: CGFloat { isRegular ? 72 : 54 }
    private var taskIconFont: CGFloat { isRegular ? 28 : 22 }
    private var taskTitleFont: CGFloat { isRegular ? 21 : 17 }
    private var taskMetaFont: CGFloat { isRegular ? 15 : 13 }
    private var taskCheckSize: CGFloat { isRegular ? 38 : 30 }
    private var taskCardPadding: CGFloat { isRegular ? 22 : 16 }
    private var taskCardSpacing: CGFloat { isRegular ? 18 : 12 }
    private var greetingFont: CGFloat { isRegular ? 16 : 14 }
    private var nameFont: CGFloat { isRegular ? 36 : 30 }
    private var sectionTitleFont: CGFloat { isRegular ? 24 : 20 }
    private var sectionCountFont: CGFloat { isRegular ? 15 : 13.5 }
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
                    Text("Hey \(TabletData.child.name)! 👋").font(Typography.display(nameFont, weight: .heavy)).foregroundStyle(KidTheme.ink)

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
                            Button { selectedTask = task } label: {
                                taskCard(task, isNext: task.id == nextTaskId)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(doneCount == tasks.count ? "All done, \(TabletData.child.name)! Your play time is unlocked! 🎉" : "Finish your tasks to unlock your play time, \(TabletData.child.name)!")
                        .font(Typography.font(15, weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .frame(maxWidth: contentMaxWidth ?? .infinity)
                .frame(maxWidth: .infinity)
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
        .fullScreenCover(item: $selectedTask) { task in
            TaskDetailView(task: task, onComplete: { photoCount, note in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].done = true
                    tasks[i].submittedPhotoCount = photoCount
                    tasks[i].submissionNote = note
                    // Submitting means "a parent hasn't looked at it yet,"
                    // not "fully approved" — see KidTask.pendingApproval.
                    // Clearing redoRequested too: a resubmission after a
                    // redo ask puts the task right back into the review
                    // queue instead of staying stuck showing the old note.
                    tasks[i].pendingApproval = true
                    tasks[i].approved = false
                    tasks[i].redoRequested = false
                }
                selectedTask = nil
            }, onRequestBypass: { reason, hasVoice in
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].bypassRequested = true
                    tasks[i].bypassNote = reason.isEmpty ? nil : reason
                    tasks[i].bypassHasVoiceNote = hasVoice
                }
            })
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "morning" : h < 18 ? "afternoon" : "evening"
    }

    // Blue "waiting on a parent to check it" — distinct from both the
    // bypass lavender (so a kid can tell "I asked to skip this" apart from
    // "I finished this, they just haven't looked yet") and the redo orange
    // right below, which read too close to this state's original amber to
    // tell apart at a glance.
    private let approvalBlueTint = Color(hex: "DBEAFE")
    private let approvalBlueText = Color(hex: "2563EB")
    // A parent asking for a redo instead of approving, rather than the
    // bright orange used for e.g. KidAccent — a redo isn't an alarm, it's
    // "almost there, one more pass."
    private let redoOrangeTint = Color(hex: "FFEDD5")
    private let redoOrangeText = Color(hex: "C2410C")

    private func taskCard(_ task: KidTask, isNext: Bool) -> some View {
        let awaitingBypass = task.bypassRequested && !task.done
        let awaitingApproval = task.done && task.pendingApproval && !task.approved
        let needsRedo = task.redoRequested
        // Redo puts a task back in "to do" territory visually (not struck
        // through, full opacity) — the banner below is what explains why,
        // rather than the row just looking like nothing ever happened.
        let doneLook = task.done && !needsRedo && !awaitingApproval

        let chipColor = needsRedo ? redoOrangeTint : (awaitingBypass ? KidTheme.lavender : (awaitingApproval ? approvalBlueTint : KidTheme.cream))
        let chipIconColor = needsRedo ? redoOrangeText : (awaitingBypass ? KidTheme.lavenderText : (awaitingApproval ? approvalBlueText : KidTheme.greenDeep))
        let chipIcon = awaitingBypass ? "hand.raised.fill" : (awaitingApproval ? "hourglass" : TabletData.sfIcon(for: task.iconTaskId))
        let ringColor = doneLook ? KidTheme.green : (needsRedo ? redoOrangeText : (awaitingBypass ? KidTheme.lavenderText : (awaitingApproval ? approvalBlueText : (isNext ? KidTheme.green : Color(hex: "D5DED8")))))

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
                    } else if awaitingApproval {
                        Label("Waiting for your parent to check it", systemImage: "hourglass")
                            .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(approvalBlueText)
                    } else if !task.done {
                        if let due = task.due {
                            Label("Due \(due)", systemImage: "clock")
                                .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                        } else {
                            Label("Anytime today", systemImage: "sparkles")
                                .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                        }
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
                        } else if awaitingApproval {
                            Image(systemName: "hourglass").font(.system(size: taskCheckSize * 0.4, weight: .bold)).foregroundStyle(approvalBlueText)
                        }
                    }
            }

            if needsRedo, let note = task.redoNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    if task.redoHasVoiceNote {
                        Image(systemName: "waveform").font(.system(size: 11, weight: .bold))
                    }
                    Text(note).font(Typography.font(taskMetaFont, weight: .regular))
                }
                .foregroundStyle(redoOrangeText)
                .padding(10)
                .background(redoOrangeTint)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(taskCardPadding)
        .background(needsRedo ? KidTheme.cream : (awaitingBypass ? KidTheme.lavender.opacity(0.5) : (awaitingApproval ? approvalBlueTint.opacity(0.6) : (isNext && !task.done ? KidTheme.greenTint : KidTheme.cream))))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(needsRedo ? redoOrangeText.opacity(0.4) : (awaitingBypass ? KidTheme.lavenderText : (awaitingApproval ? approvalBlueText.opacity(0.4) : (isNext && !task.done ? KidTheme.green : KidTheme.line)))))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .opacity(doneLook ? 0.65 : 1)
    }
}
