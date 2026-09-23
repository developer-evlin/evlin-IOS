import SwiftUI

/// Working through an assigned course: one video at a time, each with an
/// optional quiz, the next locked until this one's done.
///
/// One implementation, three callers — a reflection, a special task, and a
/// course assigned straight from the library. Whether finishing it unlocks
/// the device, completes a task or claims a prize is the caller's business;
/// this view only knows how to get through the videos.
struct CourseFlowView: View {
    let assignment: ApiCourseAssignment
    /// Called after each item is completed, with the refreshed assignment —
    /// the caller decides whether that means anything beyond "next video".
    var onItemCompleted: (() async -> Void)?

    @State private var progress: [ApiCourseItemProgress]
    @State private var selectedAnswers: [String: Int] = [:]
    @State private var videoFinished: Set<String> = []
    @State private var submitting = false
    @State private var errorText: String?

    init(assignment: ApiCourseAssignment, onItemCompleted: (() async -> Void)? = nil) {
        self.assignment = assignment
        self.onItemCompleted = onItemCompleted
        _progress = State(initialValue: assignment.orderedProgress)
    }

    private var currentIndex: Int? {
        progress.firstIndex { $0.status == "available" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title = assignment.course?.title {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(KidTheme.ink)
            }

            stepDots

            if let index = currentIndex, let item = item(at: index) {
                activeItem(item, progressRow: progress[index], number: index + 1)
            } else {
                allDone
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "C2410C"))
            }
        }
    }

    // MARK: - Pieces

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Array(progress.enumerated()), id: \.element.id) { _, row in
                Capsule()
                    .fill(row.status == "completed" ? KidTheme.greenDeep
                          : (row.status == "available" ? KidTheme.green : KidTheme.mutedBorder))
                    .frame(height: 6)
            }
        }
    }

    @ViewBuilder
    private func activeItem(_ item: ApiCourseItem, progressRow: ApiCourseItemProgress, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video \(number) of \(progress.count)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(KidTheme.inkSoft)

            if let title = item.videoTitle {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KidTheme.ink)
            }

            YouTubeEmbedView(videoID: item.videoId) {
                videoFinished.insert(item.id)
            }

            let quiz = item.quiz.filter(\.isUsable)
            if !quiz.isEmpty {
                // Only after the video actually ends — the player reports
                // that itself, so this isn't a button they can press on
                // arrival.
                if videoFinished.contains(item.id) {
                    quizSection(item: item, quiz: quiz)
                } else {
                    Text("Finish the video and the questions will appear.")
                        .font(.system(size: 14))
                        .foregroundStyle(KidTheme.inkSoft)
                }
            }

            Button {
                Task { await complete(item: item, progressRow: progressRow, quiz: quiz) }
            } label: {
                Text(submitting ? "Saving…" : (progress.count > number ? "Next video" : "Finish"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(canComplete(item: item, quiz: quiz) ? KidTheme.greenDeep : KidTheme.mutedBorder))
            }
            .buttonStyle(.plain)
            .disabled(!canComplete(item: item, quiz: quiz) || submitting)
        }
    }

    private func quizSection(item: ApiCourseItem, quiz: [ApiQuizQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(quiz.enumerated()), id: \.offset) { qIndex, question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KidTheme.ink)

                    ForEach(Array(question.options.enumerated()), id: \.offset) { oIndex, option in
                        let key = answerKey(item: item, question: qIndex)
                        let picked = selectedAnswers[key] == oIndex
                        Button {
                            selectedAnswers[key] = oIndex
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(picked ? KidTheme.greenDeep : KidTheme.mutedBorder)
                                Text(option)
                                    .font(.system(size: 15))
                                    .foregroundStyle(KidTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(picked ? KidTheme.greenTint : KidTheme.muted)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var allDone: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(KidTheme.greenDeep)
            Text("All done — nice work!")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KidTheme.ink)
        }
    }

    // MARK: - Logic

    private func item(at index: Int) -> ApiCourseItem? {
        guard index < progress.count else { return nil }
        return assignment.item(for: progress[index])
    }

    private func answerKey(item: ApiCourseItem, question: Int) -> String { "\(item.id)-\(question)" }

    private func canComplete(item: ApiCourseItem, quiz: [ApiQuizQuestion]) -> Bool {
        guard !quiz.isEmpty else { return videoFinished.contains(item.id) }
        guard videoFinished.contains(item.id) else { return false }
        return (0..<quiz.count).allSatisfy { selectedAnswers[answerKey(item: item, question: $0)] != nil }
    }

    private func complete(item: ApiCourseItem, progressRow: ApiCourseItemProgress, quiz: [ApiQuizQuestion]) async {
        guard !submitting else { return }
        submitting = true
        errorText = nil
        defer { submitting = false }

        let answers = quiz.isEmpty ? nil
            : (0..<quiz.count).map { selectedAnswers[answerKey(item: item, question: $0)] ?? 0 }

        do {
            _ = try await APIClient.shared.completeCourseItem(progressId: progressRow.id, quizAnswers: answers)
            // Re-read rather than patching local state: the server decides
            // what unlocks next, and guessing here is how the two get out of
            // step.
            if let refreshed = try? await APIClient.shared.fetchCourseAssignments(childId: assignment.childId)
                .first(where: { $0.id == assignment.id }) {
                progress = refreshed.orderedProgress
            }
            await onItemCompleted?()
        } catch {
            errorText = "That didn't save — check your connection and try again."
        }
    }
}
