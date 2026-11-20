import SwiftUI

// Under Home's greeting, only when the child has sent a goal check-in today
// that waits for the parent: one ring per such goal, the way a new story
// shows at the top of Instagram, in the goal's colour with a halo. Tapping
// one opens today's check-in to approve (GoalStoryViewer). Once answered,
// the ring goes, and with nothing waiting the row isn't there at all.
struct HomeStories: View {
    @ObservedObject var child: Child
    @ObservedObject private var goalStore = GoalStore.shared
    @State private var viewing: Goal?
    @State private var tick = 0

    var body: some View {
        let waiting = goalStore.goals(for: child.id).filter { !$0.waitingToday.isEmpty }
        Group {
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(child.name) sent \(waiting.count == 1 ? "a goal check-in" : "\(waiting.count) goal check-ins")")
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(Neutral.secondary)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(waiting) { story($0) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)
                    .scrollIndicators(.hidden)
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.3), value: waiting.map(\.id))
        .sensoryFeedback(.selection, trigger: tick)
        .fullScreenCover(item: $viewing) { goal in
            GoalStoryViewer(goalId: goal.id, childName: child.name) { viewing = nil }
        }
        .task {
            // Demo screenshots: -EvlinParentOpen story opens the first one.
            if DemoMode.parentOpen == "story" { viewing = goalStore.goals(for: child.id).first { !$0.waitingToday.isEmpty } }
        }
    }

    private func story(_ goal: Goal) -> some View {
        Button {
            tick += 1
            viewing = goal
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(LinearGradient(colors: goal.colors, startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 3)
                    Group {
                        if let photo = goal.waitingToday.last?.photo {
                            ProofPhoto(ref: photo, cornerRadius: 30)
                                .clipShape(Circle())
                        } else {
                            Circle().fill(goal.colors[0].opacity(0.12))
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(goal.colors[0])
                        }
                    }
                    .frame(width: 58, height: 58)
                }
                .frame(width: 68, height: 68)
                Text(goal.title)
                    .font(Typography.font(12, weight: .medium))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                    .frame(width: 76)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.title), today's check-in to approve")
        .accessibilityAddTraits(.isButton)
    }
}
