import SwiftUI

// Tapping a goal opens today's check-in the way a story opens, with
// Approve / Redo (the kid can check in again today). Only today's: the parent answers the day in front
// of them and never sees earlier days here. When the child sent more than
// one today, tapping the photo's sides steps between them. The ••• menu
// holds the rest (edit, We did it, delete).
struct GoalStoryViewer: View {
    var goalId: String
    var childName: String
    var onClose: () -> Void

    @ObservedObject private var store = GoalStore.shared
    @State private var index: Int?
    @State private var showDetails = false
    @State private var answeredTick = 0
    @State private var jumpTick = 0

    private var goal: Goal? { store.goals.first { $0.id == goalId } }

    var body: some View {
        if let goal {
            let entries = goal.entries.filter { Calendar.current.isDateInToday($0.at) }.sorted { $0.at < $1.at }
            let i = min(index ?? startIndex(entries), max(0, entries.count - 1))
            VStack(spacing: 0) {
                header(goal)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ZStack {
                    if entries.isEmpty {
                        empty(goal)
                    } else {
                        page(goal, entries[i])
                            .id(entries[i].id)
                            .transition(.opacity)
                    }
                    // Tap the sides to move between check-ins.
                    if entries.count > 1 {
                        HStack(spacing: 0) {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { step(-1, i, entries.count) }
                                .accessibilityLabel("Earlier check-in")
                                .accessibilityAddTraits(.isButton)
                            Color.clear.frame(maxWidth: .infinity)
                                .allowsHitTesting(false)
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { step(1, i, entries.count) }
                                .accessibilityLabel("Later check-in")
                                .accessibilityAddTraits(.isButton)
                        }
                        .padding(.bottom, 120)
                    }
                }
                .frame(maxHeight: .infinity)

                if let entry = entries.isEmpty ? nil : entries[i] {
                    footer(goal, entry)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                }
            }
            .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
            .animation(.easeOut(duration: 0.2), value: i)
            .sensoryFeedback(.success, trigger: answeredTick)
            .sensoryFeedback(.selection, trigger: jumpTick)
            // Reached, it's a milestone now: its moment plays over this.
            .onChange(of: goal.finishedAt) { _, at in if at != nil { onClose() } }
            .sheet(isPresented: $showDetails) {
                if let child = FamilyStore.children.first(where: { $0.id == goal.childId }) {
                    NewGoalSheet(child: child, editing: goal)
                        .presentationDragIndicator(.visible)
                }
            }
        } else {
            Color.white.onAppear(perform: onClose)
        }
    }

    /// The latest of today's still waiting, otherwise the latest.
    private func startIndex(_ entries: [GoalCheckIn]) -> Int {
        entries.lastIndex { $0.status == .waiting } ?? max(0, entries.count - 1)
    }

    private func step(_ by: Int, _ i: Int, _ count: Int) {
        let n = i + by
        guard n >= 0, n < count else { return }
        jumpTick += 1
        index = n
    }

    // MARK: - Parts

    private func header(_ goal: Goal) -> some View {
        HStack(spacing: 12) {
            GoalRing(goal: goal, size: 40, line: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.title)
                    .font(Typography.font(16, weight: .bold))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                Text(goal.prize.isEmpty ? goal.leftWords() : "\(goal.leftWords()) · \(goal.prize)")
                    .font(Typography.font(13, weight: .regular))
                    .foregroundStyle(Neutral.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { showDetails = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Neutral.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit habit")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Neutral.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    /// One check-in: the photo, large, and when it was sent.
    private func page(_ goal: Goal, _ entry: GoalCheckIn) -> some View {
        VStack(spacing: 14) {
            if let photo = entry.photo {
                ProofPhoto(ref: photo, cornerRadius: 22)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
            } else {
                Text("\(childName) said they did it.")
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(Neutral.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Neutral.tile, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
            }
            Text(CheckInLook.when(entry.at))
                .font(Typography.font(14, weight: .semibold))
                .foregroundStyle(Neutral.secondary)
        }
        .padding(.vertical, 10)
    }

    private func empty(_ goal: Goal) -> some View {
        VStack(spacing: 10) {
            Image(systemName: goal.needsPhoto ? "camera" : "checkmark.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Neutral.secondary)
            Text("Nothing from \(childName) today")
                .font(Typography.font(18, weight: .bold))
                .foregroundStyle(Neutral.ink)
            Text("When they \(goal.needsPhoto ? "hold the ring and take a photo" : "hold the ring") on their iPad, it shows up here.")
                .font(Typography.font(14.5, weight: .regular))
                .foregroundStyle(Neutral.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    /// A waiting check-in: Approve / Redo. An answered one: how.
    @ViewBuilder private func footer(_ goal: Goal, _ entry: GoalCheckIn) -> some View {
        if entry.status == .waiting {
            HStack(spacing: 10) {
                Button {
                    answeredTick += 1
                    store.review(goal, entry: entry.id, approved: false)
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.backward")
                        .font(Typography.font(16, weight: .semibold))
                        .foregroundStyle(Neutral.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TemplateStyle.ring))
                }
                .buttonStyle(.plain)
                Button {
                    answeredTick += 1
                    store.review(goal, entry: entry.id, approved: true)
                } label: {
                    HStack(spacing: 6) {
                        ApproveCheck(fontSize: 16)
                        Text("Approve")
                    }
                    .font(Typography.font(16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(FormGreen.approve, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(spacing: 4) {
                Text(CheckInLook.word(entry.status))
                    .font(Typography.font(16, weight: .bold))
                    .foregroundStyle(CheckInLook.color(entry.status))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
        }
    }
}
