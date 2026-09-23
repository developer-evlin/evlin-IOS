import SwiftUI

/// What the agent found, before any of it reaches the child.
///
/// The videos here are real search results that were checked against their
/// own metadata — so the card shows each one's title, channel and the
/// agent's stated reason, which is the thing a parent can actually judge.
/// Nothing is assigned until they tap the button: approving publishes the
/// course to the shared library and assigns it, and for a special task the
/// same tap creates the task in one transaction.
struct CourseProposalCard: View {
    let courseId: String
    let title: String
    /// Non-nil means this is a special task proposal — the course becomes a
    /// task worth this many minutes rather than being assigned on its own.
    let bonusMinutes: Int?
    var onDone: (String) -> Void

    @State private var course: ApiCourse?
    @State private var working = false
    @State private var finished = false
    @State private var errorText: String?

    private var isSpecialTask: Bool { bonusMinutes != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let course {
                ForEach(course.items, id: \.id) { item in
                    videoRow(item)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            }

            if let errorText {
                Text(errorText)
                    .font(Typography.font(13, weight: .medium))
                    .foregroundStyle(Color(hex: "C2410C"))
            }

            if !finished { actionButton }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
        .task { course = try? await APIClient.shared.fetchCourse(courseId: courseId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isSpecialTask ? title : (course?.title ?? title))
                .font(Typography.display(17, weight: .bold))
            if let minutes = bonusMinutes, minutes > 0 {
                Text("Earns \(minutes) minutes of screen time")
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(Brand.greenDeep)
            }
            Text("\(course?.items.count ?? 0) video\((course?.items.count ?? 0) == 1 ? "" : "s") · checked for age and topic")
                .font(Typography.font(12, weight: .medium))
                .foregroundStyle(Brand.inkSoft)
        }
    }

    private func videoRow(_ item: ApiCourseItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(item.orderIndex + 1)")
                .font(Typography.font(12, weight: .bold))
                .foregroundStyle(Brand.inkSoft)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Brand.greenTint))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.videoTitle ?? item.videoId)
                    .font(Typography.font(14, weight: .semibold))
                    .lineLimit(2)
                if let channel = item.channelTitle {
                    Text(channel)
                        .font(Typography.font(12))
                        .foregroundStyle(Brand.inkSoft)
                }
                if let reason = item.vettingNotes, !reason.isEmpty {
                    Text(reason)
                        .font(Typography.font(12))
                        .foregroundStyle(Brand.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let usable = item.quiz.filter(\.isUsable).count
                if usable > 0 {
                    Text("\(usable) question\(usable == 1 ? "" : "s")")
                        .font(Typography.font(11, weight: .semibold))
                        .foregroundStyle(Brand.greenDeep)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actionButton: some View {
        Button {
            Task { await confirm() }
        } label: {
            Text(working ? "Saving…" : (isSpecialTask ? "Create this task" : "Send to my child"))
                .font(Typography.font(15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(Brand.greenDeep))
        }
        .buttonStyle(.plain)
        .disabled(working || course == nil)
    }

    private func confirm() async {
        guard !working, let childId = SessionManager.shared.activeChildId else { return }
        working = true
        errorText = nil
        defer { working = false }

        do {
            if let minutes = bonusMinutes {
                // One call: creating the task publishes the drafted course
                // and assigns it, so there's no window where the task points
                // at something unpublished.
                _ = try await APIClient.shared.createTask(
                    childId: childId, title: title, instructions: nil, recurrence: "none",
                    category: "Learning", submissionKind: "course",
                    bonusMinutes: minutes, courseId: courseId, createdBy: "ai_agent"
                )
                finished = true
                onDone("Created \"\(title)\" — your child earns \(minutes) minutes for finishing it.")
            } else {
                _ = try await APIClient.shared.approveCourse(courseId: courseId, assignToChildId: childId)
                finished = true
                onDone("Sent \"\(course?.title ?? title)\" to your child. It's in your library for next time too.")
            }
            await AppSync.shared.syncBackendData()
        } catch {
            errorText = "That didn't save. \(error.apiUserMessage)"
        }
    }
}
