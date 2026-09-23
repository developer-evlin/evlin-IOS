import SwiftUI

/// Milestones: longer-arc goals with a prize, separate from day-to-day tasks.
///
/// Three things share this screen because they're the same object at
/// different stages: what the child has asked for and is waiting on, what's
/// in progress, and what's finished and owed a prize.
struct ScreenMilestones: View {
    let childId: String
    let childName: String

    @State private var milestones: [ApiMilestone] = []
    @State private var loading = true
    @State private var showCreate = false
    @State private var approving: ApiMilestone?
    @State private var errorText: String?

    private var proposals: [ApiMilestone] { milestones.filter { $0.status == "proposed" } }
    private var active: [ApiMilestone] { milestones.filter { $0.status == "active" } }
    private var achieved: [ApiMilestone] { milestones.filter { $0.status == "achieved" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    if !proposals.isEmpty {
                        section("\(childName) asked for", proposals) { milestone in
                            MilestoneRow(milestone: milestone, actionTitle: "Set it up") {
                                approving = milestone
                            }
                        }
                    }

                    if !active.isEmpty {
                        section("In progress", active) { milestone in
                            MilestoneRow(milestone: milestone,
                                         actionTitle: milestone.achievable ? "Give the prize" : nil) {
                                Task { await claim(milestone) }
                            }
                        }
                    }

                    if !achieved.isEmpty {
                        section("Done", achieved) { milestone in
                            MilestoneRow(milestone: milestone, actionTitle: nil, action: {})
                        }
                    }

                    if milestones.isEmpty {
                        emptyState
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(Typography.font(13, weight: .medium))
                        .foregroundStyle(Color(hex: "C2410C"))
                }
            }
            .padding(20)
        }
        .background(Brand.surfaceSoft.ignoresSafeArea())
        .task { await reload() }
        .sheet(isPresented: $showCreate) {
            MilestoneCreateSheet(childId: childId) { await reload() }
        }
        .sheet(item: $approving) { milestone in
            MilestoneApprovalSheet(milestone: milestone) { await reload() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Milestones")
                    .font(Typography.display(26, weight: .heavy))
                Text("Bigger goals \(childName) works toward over time")
                    .font(Typography.font(14))
                    .foregroundStyle(Brand.inkSoft)
            }
            Spacer()
            Button { showCreate = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Brand.greenDeep))
            }
            .buttonStyle(.plain)
        }
    }

    private func section<Row: View>(_ title: String, _ items: [ApiMilestone],
                                    @ViewBuilder row: @escaping (ApiMilestone) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Typography.font(13, weight: .heavy))
                .foregroundStyle(Brand.inkSoft)
                .textCase(.uppercase)
            ForEach(items, id: \.id) { row($0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No milestones yet")
                .font(Typography.font(16, weight: .bold))
            Text("Set a goal \(childName) can work toward — or wait for them to suggest one.")
                .font(Typography.font(14))
                .foregroundStyle(Brand.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        if let fresh = try? await APIClient.shared.fetchMilestones(childId: childId) {
            milestones = fresh
        }
    }

    private func claim(_ milestone: ApiMilestone) async {
        do {
            _ = try await APIClient.shared.claimMilestone(milestoneId: milestone.id)
            await AppSync.shared.syncBackendData()   // the prize lands in the time pool
            await reload()
        } catch {
            errorText = "Couldn't give the prize. \(error.apiUserMessage)"
        }
    }
}

private struct MilestoneRow: View {
    let milestone: ApiMilestone
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Brand.greenDeep)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Brand.greenTint))

                VStack(alignment: .leading, spacing: 3) {
                    Text(milestone.title)
                        .font(Typography.font(15, weight: .bold))
                    if let description = milestone.description, !description.isEmpty {
                        Text(description)
                            .font(Typography.font(13))
                            .foregroundStyle(Brand.inkSoft)
                    }
                    Text(subtitle)
                        .font(Typography.font(12, weight: .semibold))
                        .foregroundStyle(Brand.inkSoft)
                }
                Spacer(minLength: 0)
            }

            if let target = milestone.targetCount, target > 0, milestone.kind != "course" {
                ProgressView(value: Double(min(milestone.progressCount, target)), total: Double(target))
                    .tint(Brand.greenDeep)
            }

            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typography.font(14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Brand.greenDeep))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var icon: String {
        switch milestone.kind {
        case "course": return "play.rectangle.fill"
        case "streak": return "flame.fill"
        case "custom": return "sparkles"
        default: return "target"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch milestone.kind {
        case "course":
            parts.append("Finish the lesson plan")
        case "custom":
            parts.append(milestone.createdBy == "child" ? "Their idea" : "Custom")
        default:
            if let target = milestone.targetCount {
                parts.append("\(milestone.progressCount) of \(target) tasks")
            }
        }
        if milestone.prizeMinutes > 0 { parts.append("\(milestone.prizeMinutes) min prize") }
        if let prize = milestone.prizeText, !prize.isEmpty { parts.append(prize) }
        return parts.joined(separator: " · ")
    }
}

extension ApiMilestone: Identifiable {}
