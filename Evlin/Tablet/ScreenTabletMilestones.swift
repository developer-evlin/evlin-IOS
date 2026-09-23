import SwiftUI

/// What the kid is working toward, and a place to add their own ideas.
///
/// Anything they add here is a suggestion, not a done deal — a grown-up
/// decides whether it becomes real and what it's worth. That's said plainly
/// on the screen rather than discovered when nothing happens, because a kid
/// typing in a wish and watching it silently do nothing is worse than being
/// told up front that someone has to say yes.
struct ScreenTabletMilestones: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    @State private var milestones: [ApiMilestone] = []
    @State private var loading = true
    @State private var showAdd = false

    private var waiting: [ApiMilestone] { milestones.filter { $0.status == "proposed" } }
    private var working: [ApiMilestone] { milestones.filter { $0.status == "active" } }
    private var done: [ApiMilestone] { milestones.filter { $0.status == "achieved" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    if !working.isEmpty { group("Working on", working) }
                    if !waiting.isEmpty { group("Waiting for a grown-up", waiting) }
                    if !done.isEmpty { group("Done!", done) }
                    if milestones.isEmpty { emptyState }
                }

                addButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 100)
            .kidContentColumn(kid.contentMaxWidth)
        }
        .background(KidTheme.background)
        .task { await reload() }
        .sheet(isPresented: $showAdd) {
            KidMilestoneIdeaSheet { await reload() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("My goals")
                .font(Typography.display(kid.of(26, 30), weight: .heavy))
                .foregroundStyle(KidTheme.ink)
            Text("Big things you're working toward")
                .font(Typography.font(kid.of(13, 15), weight: .semibold))
                .foregroundStyle(KidTheme.inkSoft)
        }
    }

    private func group(_ title: String, _ items: [ApiMilestone]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Typography.display(kid.of(17, 20), weight: .heavy))
                .foregroundStyle(KidTheme.ink)
                .padding(.top, 8)
            ForEach(items, id: \.id) { KidMilestoneCard(milestone: $0, kid: kid) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing yet")
                .font(Typography.font(kid.of(15, 17), weight: .heavy))
                .foregroundStyle(KidTheme.ink)
            Text("Add something you'd love to work toward.")
                .font(Typography.font(kid.of(13, 15), weight: .semibold))
                .foregroundStyle(KidTheme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add my own idea")
            }
            .font(Typography.font(kid.of(15, 17), weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, kid.of(14, 16))
            .background(Capsule().fill(KidTheme.greenDeep))
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        guard let childId = SessionManager.shared.activeChildId else { return }
        if let fresh = try? await APIClient.shared.fetchMilestones(childId: childId) {
            milestones = fresh
        }
    }
}

private struct KidMilestoneCard: View {
    let milestone: ApiMilestone
    let kid: KidAdaptive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(emoji).font(.system(size: kid.of(24, 28)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(milestone.title)
                        .font(Typography.font(kid.of(15, 17), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text(subtitle)
                        .font(Typography.font(kid.of(12.5, 14), weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                Spacer(minLength: 0)
            }

            if milestone.status == "active", let target = milestone.targetCount, target > 0,
               milestone.kind != "course" {
                ProgressView(value: Double(min(milestone.progressCount, target)), total: Double(target))
                    .tint(KidTheme.greenDeep)
            }
        }
        .padding(kid.of(14, 18))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var emoji: String {
        if milestone.status == "achieved" { return "🎉" }
        if milestone.status == "proposed" { return "💭" }
        switch milestone.kind {
        case "course": return "📺"
        case "streak": return "🔥"
        default: return "🎯"
        }
    }

    private var background: Color {
        switch milestone.status {
        case "achieved": return KidTheme.greenTint
        case "proposed": return KidTheme.muted
        default: return Color(hex: "F0F4FF")
        }
    }

    private var subtitle: String {
        if milestone.status == "proposed" { return "Waiting for a grown-up to say yes" }
        if milestone.status == "achieved" { return "You did it!" }
        var parts: [String] = []
        if milestone.kind == "course" {
            parts.append("Watch and answer")
        } else if let target = milestone.targetCount {
            parts.append("\(milestone.progressCount) of \(target)")
        }
        if milestone.prizeMinutes > 0 { parts.append("\(milestone.prizeMinutes) bonus minutes") }
        if let prize = milestone.prizeText, !prize.isEmpty { parts.append(prize) }
        return parts.joined(separator: " · ")
    }
}

private struct KidMilestoneIdeaSheet: View {
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var why = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What would you like to work toward?") {
                    TextField("e.g. A new skateboard", text: $title)
                    TextField("Why? (optional)", text: $why, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Text("A grown-up will see this and decide what it takes to earn it.")
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(Color(hex: "C2410C"))
                }
            }
            .navigationTitle("My idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Sending…" : "Send") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func save() async {
        guard let childId = SessionManager.shared.activeChildId else { return }
        saving = true
        defer { saving = false }
        do {
            try await APIClient.shared.proposeMilestone(
                childId: childId,
                title: title.trimmingCharacters(in: .whitespaces),
                description: why.isEmpty ? nil : why
            )
            await onSaved()
            dismiss()
        } catch {
            errorText = "That didn't send. Try again in a moment."
        }
    }
}
