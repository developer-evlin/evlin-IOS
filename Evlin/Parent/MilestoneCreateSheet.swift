import SwiftUI

/// Creating a milestone, from one of two templates.
///
/// They're genuinely different things rather than one form with a toggle: a
/// task goal is counted (do this N times), a lesson plan is completed (watch
/// and answer all of it). The backend tracks them separately for that
/// reason, so asking which one up front avoids a form full of fields that
/// only apply half the time.
struct MilestoneCreateSheet: View {
    let childId: String
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Template { case taskGoal, lessonPlan }
    @State private var template: Template?

    var body: some View {
        NavigationStack {
            Group {
                switch template {
                case .none:        templatePicker
                case .taskGoal:    TaskGoalForm(childId: childId, onSaved: finish)
                case .lessonPlan:  LessonPlanForm(childId: childId, onSaved: finish)
                }
            }
            .background(Brand.surfaceSoft.ignoresSafeArea())
            .navigationTitle(template == nil ? "New milestone" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(template == nil ? "Cancel" : "Back") {
                        if template == nil { dismiss() } else { template = nil }
                    }
                }
            }
        }
    }

    private func finish() async {
        await onSaved()
        dismiss()
    }

    private var templatePicker: some View {
        VStack(spacing: 14) {
            templateCard(
                icon: "target",
                title: "Task goal",
                blurb: "Counts up as tasks get approved — \"ten chores\", \"five days in a row\".",
                action: { template = .taskGoal }
            )
            templateCard(
                icon: "play.rectangle.fill",
                title: "Lesson plan",
                blurb: "Finish a course of vetted videos and their questions.",
                action: { template = .lessonPlan }
            )
            Spacer()
        }
        .padding(20)
    }

    private func templateCard(icon: String, title: String, blurb: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.greenDeep)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Brand.greenTint))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typography.font(16, weight: .bold))
                    Text(blurb)
                        .font(Typography.font(13))
                        .foregroundStyle(Brand.inkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Template 1: a counted task goal

private struct TaskGoalForm: View {
    let childId: String
    var onSaved: () async -> Void

    @State private var title = ""
    @State private var streak = false
    @State private var target = 10
    @State private var prizeMinutes = 30
    @State private var prizeText = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("What are they working toward?") {
                TextField("e.g. Ten chores done", text: $title)
                Toggle("Days in a row", isOn: $streak)
                Stepper("\(target) \(streak ? "days" : "tasks")", value: $target, in: 1...100)
            }
            Section("Prize") {
                Stepper(prizeMinutes > 0 ? "\(prizeMinutes) extra minutes" : "No extra minutes",
                        value: $prizeMinutes, in: 0...240, step: 5)
                TextField("Or something else (optional)", text: $prizeText)
            }
            Section {
                Text("Tag tasks to this milestone when you create them — approving a tagged task is what moves it forward.")
                    .font(Typography.font(13))
                    .foregroundStyle(Brand.inkSoft)
            }
            if let errorText {
                Text(errorText).foregroundStyle(Color(hex: "C2410C"))
            }
            Section {
                Button(saving ? "Saving…" : "Create milestone") { Task { await save() } }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await APIClient.shared.createMilestone(
                childId: childId, title: title.trimmingCharacters(in: .whitespaces),
                kind: streak ? "streak" : "count", targetCount: target,
                prizeText: prizeText.isEmpty ? nil : prizeText, prizeMinutes: prizeMinutes
            )
            await onSaved()
        } catch {
            errorText = "That didn't save. \(error.apiUserMessage)"
        }
    }
}

// MARK: - Template 2: a lesson plan to finish

private struct LessonPlanForm: View {
    let childId: String
    var onSaved: () async -> Void

    @State private var title = ""
    @State private var topic = ""
    @State private var videoCount = 3
    @State private var prizeMinutes = 30
    @State private var prizeText = ""
    @State private var draft: ApiCourse?
    @State private var generating = false
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("What should it teach?") {
                TextField("Topic, e.g. the water cycle", text: $topic)
                Stepper("\(videoCount) video\(videoCount == 1 ? "" : "s")", value: $videoCount, in: 1...10)
                Button(generating ? "Finding videos…" : "Find videos") { Task { await generate() } }
                    .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || generating)
            }

            if let draft {
                Section("Found — check these over") {
                    ForEach(draft.items, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.videoTitle ?? item.videoId)
                                .font(Typography.font(14, weight: .semibold))
                            if let channel = item.channelTitle {
                                Text(channel).font(Typography.font(12)).foregroundStyle(Brand.inkSoft)
                            }
                            if let reason = item.vettingNotes, !reason.isEmpty {
                                Text(reason)
                                    .font(Typography.font(12))
                                    .foregroundStyle(Brand.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Section("Milestone") {
                    TextField("Title", text: $title)
                    Stepper(prizeMinutes > 0 ? "\(prizeMinutes) extra minutes" : "No extra minutes",
                            value: $prizeMinutes, in: 0...240, step: 5)
                    TextField("Or something else (optional)", text: $prizeText)
                }
            }

            if let errorText {
                Text(errorText).foregroundStyle(Color(hex: "C2410C"))
            }

            if draft != nil {
                Section {
                    Button(saving ? "Saving…" : "Create milestone") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func generate() async {
        generating = true
        errorText = nil
        defer { generating = false }
        do {
            let course = try await APIClient.shared.generateCourse(
                topic: topic.trimmingCharacters(in: .whitespaces),
                videoCount: videoCount, childId: childId
            )
            draft = course
            if title.isEmpty { title = course.title }
        } catch {
            errorText = "Couldn't build that lesson plan. \(error.apiUserMessage)"
        }
    }

    private func save() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        do {
            // Creating the milestone publishes the drafted course and
            // assigns it, in one call — the same one-transaction rule as
            // creating a special task from a proposal.
            _ = try await APIClient.shared.createMilestone(
                childId: childId, title: title.trimmingCharacters(in: .whitespaces),
                kind: "course", prizeText: prizeText.isEmpty ? nil : prizeText,
                prizeMinutes: prizeMinutes, courseId: draft.id
            )
            await onSaved()
        } catch {
            errorText = "That didn't save. \(error.apiUserMessage)"
        }
    }
}

// MARK: - Turning a child's suggestion into a real milestone

struct MilestoneApprovalSheet: View {
    let milestone: ApiMilestone
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var countIt = true
    @State private var target = 10
    @State private var prizeMinutes = 0
    @State private var prizeText = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("They asked for") {
                    Text(milestone.title).font(Typography.font(16, weight: .bold))
                    if let description = milestone.description, !description.isEmpty {
                        Text(description).foregroundStyle(Brand.inkSoft)
                    }
                }
                Section("What does it take?") {
                    Toggle("Count tasks toward it", isOn: $countIt)
                    if countIt {
                        Stepper("\(target) tasks", value: $target, in: 1...100)
                    } else {
                        Text("You'll decide when they've earned it.")
                            .font(Typography.font(13))
                            .foregroundStyle(Brand.inkSoft)
                    }
                }
                Section("Prize") {
                    Stepper(prizeMinutes > 0 ? "\(prizeMinutes) extra minutes" : "No extra minutes",
                            value: $prizeMinutes, in: 0...240, step: 5)
                    TextField(milestone.title, text: $prizeText)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(Color(hex: "C2410C"))
                }
            }
            .background(Brand.surfaceSoft.ignoresSafeArea())
            .navigationTitle("Set it up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Approve") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
        .onAppear {
            // Their own words are the obvious default for what they get.
            if prizeText.isEmpty { prizeText = milestone.title }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await APIClient.shared.approveMilestone(
                milestoneId: milestone.id,
                kind: countIt ? "count" : "custom",
                targetCount: countIt ? target : nil,
                prizeText: prizeText.isEmpty ? nil : prizeText,
                prizeMinutes: prizeMinutes
            )
            await onSaved()
            dismiss()
        } catch {
            errorText = "That didn't save. \(error.apiUserMessage)"
        }
    }
}
