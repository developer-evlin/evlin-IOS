import SwiftUI

/// The kid's side of a reflection: watch, answer, write, hand in.
///
/// This is the only way out of a reflection lock, so it has to be reachable
/// whenever one is open — a gate with no door is just a broken device. It
/// deliberately can't be dismissed while the reflection is unfinished.
struct ReflectionFlowView: View {
    let reflection: ApiReflection
    /// Called after a successful hand-in, so the host can re-sync and let
    /// the lock re-evaluate.
    var onSubmitted: (() async -> Void)?

    @State private var assignment: ApiCourseAssignment?
    @State private var writtenResponse = ""
    @State private var submitting = false
    @State private var errorText: String?
    @FocusState private var writingFocused: Bool

    private var videosDone: Bool {
        guard let assignment else { return false }
        let rows = assignment.orderedProgress
        return !rows.isEmpty && rows.allSatisfy { $0.status == "completed" }
    }

    private var needsWriting: Bool {
        !(reflection.writtenPrompt ?? "").isEmpty
    }

    private var canSubmit: Bool {
        videosDone && (!needsWriting || !writtenResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if reflection.status == "needs_redo", let note = reflection.reviewNote, !note.isEmpty {
                    redoNote(note)
                }

                if let assignment {
                    CourseFlowView(assignment: assignment) {
                        await reloadAssignment()
                    }
                } else {
                    ProgressView().padding(.vertical, 40)
                }

                if videosDone && needsWriting {
                    writingSection
                }

                if videosDone {
                    submitButton
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: "C2410C"))
                }
            }
            .padding(24)
        }
        .background(KidTheme.background.ignoresSafeArea())
        .task { await reloadAssignment() }
        .onAppear { writtenResponse = reflection.writtenResponse ?? "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Time to reflect")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(KidTheme.ink)
            Text(reflection.status == "submitted"
                 ? "Handed in — waiting for a grown-up to have a look."
                 : "Watch, answer, and write a little. Then your device unlocks.")
                .font(.system(size: 15))
                .foregroundStyle(KidTheme.inkSoft)
        }
    }

    private func redoNote(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(KidTheme.lavenderText)
            VStack(alignment: .leading, spacing: 4) {
                Text("Have another go")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(KidTheme.ink)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(KidTheme.inkSoft)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KidTheme.lavender))
    }

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reflection.writtenPrompt ?? "")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KidTheme.ink)

            TextEditor(text: $writtenResponse)
                .focused($writingFocused)
                .font(.system(size: 15))
                .frame(minHeight: 120)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(KidTheme.line, lineWidth: 1)
                )
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Text(submitting ? "Sending…" : "Hand it in")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(canSubmit ? KidTheme.greenDeep : KidTheme.mutedBorder))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || submitting)
    }

    private func reloadAssignment() async {
        guard let refreshed = try? await APIClient.shared
            .fetchCourseAssignments(childId: reflection.childId)
            .first(where: { $0.id == reflection.courseAssignmentId }) else { return }
        assignment = refreshed
    }

    private func submit() async {
        guard !submitting else { return }
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            _ = try await APIClient.shared.submitReflection(
                reflectionId: reflection.id,
                writtenResponse: needsWriting ? writtenResponse : nil
            )
            await onSubmitted?()
        } catch {
            errorText = "That didn't send — check your connection and try again."
        }
    }
}
