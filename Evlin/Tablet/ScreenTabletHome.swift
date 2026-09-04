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
    private var contentMaxWidth: CGFloat? { isRegular ? 640 : nil }
    private var taskIconSize: CGFloat { isRegular ? 60 : 54 }
    private var taskIconFont: CGFloat { isRegular ? 24 : 22 }
    private var taskTitleFont: CGFloat { isRegular ? 19 : 17 }
    private var taskMetaFont: CGFloat { isRegular ? 13.5 : 13 }
    private var taskCheckSize: CGFloat { isRegular ? 34 : 30 }
    private var taskCardPadding: CGFloat { isRegular ? 18 : 16 }
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
                    Text("Good \(greeting)").font(Typography.font(14, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                    Text("Hey \(TabletData.child.name)! 👋").font(Typography.display(30, weight: .heavy)).foregroundStyle(KidTheme.ink)

                    HStack {
                        Text("Today").font(Typography.display(20, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Spacer()
                        Text("\(doneCount) of \(tasks.count) done")
                            .font(Typography.font(13.5, weight: .heavy))
                            .foregroundStyle(doneCount == tasks.count ? KidTheme.greenDeep : KidTheme.inkSoft)
                    }
                    .padding(.top, 22).padding(.bottom, 13)

                    VStack(spacing: isRegular ? 16 : 12) {
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

    private func taskCard(_ task: KidTask, isNext: Bool) -> some View {
        let awaitingBypass = task.bypassRequested && !task.done
        return HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14)
                .fill(awaitingBypass ? KidTheme.lavender : KidTheme.cream)
                .frame(width: taskIconSize, height: taskIconSize)
                .overlay(
                    Image(systemName: awaitingBypass ? "hand.raised.fill" : TabletData.sfIcon(for: task.iconTaskId))
                        .font(.system(size: taskIconFont))
                        .foregroundStyle(awaitingBypass ? KidTheme.lavenderText : KidTheme.greenDeep)
                        .opacity(task.done ? 0.5 : 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                if isNext && !task.done && !awaitingBypass {
                    Text("NEXT").font(Typography.font(10.5, weight: .bold)).tracking(0.6)
                        .foregroundStyle(KidTheme.greenDeep)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.white).clipShape(Capsule())
                }
                Text(task.title)
                    .font(Typography.font(taskTitleFont, weight: .semibold))
                    .foregroundStyle(task.done ? KidTheme.inkSoft : KidTheme.ink)
                    .strikethrough(task.done, color: Color(hex: "B5C8BC"))
                if awaitingBypass {
                    Label("Waiting on a parent", systemImage: "hand.raised.fill")
                        .font(Typography.font(taskMetaFont, weight: .medium)).foregroundStyle(KidTheme.lavenderText)
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
                .fill(task.done ? KidTheme.green : .white)
                .frame(width: taskCheckSize, height: taskCheckSize)
                .overlay(Circle().strokeBorder(task.done ? KidTheme.green : (awaitingBypass ? KidTheme.lavenderText : (isNext ? KidTheme.green : Color(hex: "D5DED8"))), lineWidth: 2))
                .overlay(task.done ? Image(systemName: "checkmark").font(.system(size: taskCheckSize * 0.46, weight: .bold)).foregroundStyle(.white) : nil)
        }
        .padding(taskCardPadding)
        .background(awaitingBypass ? KidTheme.lavender.opacity(0.5) : (isNext && !task.done ? KidTheme.greenTint : KidTheme.cream))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(awaitingBypass ? KidTheme.lavenderText : (isNext && !task.done ? KidTheme.green : KidTheme.line)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .opacity(task.done ? 0.65 : 1)
    }
}
