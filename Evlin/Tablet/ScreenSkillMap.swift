import SwiftUI

// The kid-side "Ring" tab (formerly "Skill Map") — a ring of task tokens
// spaced evenly around a dial, with the dial's own outline filling in as
// tasks complete (progressFill). Used to be a literal clock face (each
// token sitting at the hour position matching its deadline), but real due
// times cluster within the same few evening hours far too tightly for that
// to read cleanly — two tasks even at the same due time would sit right on
// top of each other — and completion is already communicated by the fill
// arc and each token's own checkmark, not by where around the dial a task
// happens to sit. Evenly spacing them instead keeps every token legible
// regardless of how the day's due times happen to land. On first
// appearance every token starts collapsed at the center and springs out to
// its resting spot, staggered in list order, so the dial visibly
// "assembles itself" rather than just being there.
struct ScreenRing: View {
    var tasks: [KidTask]

    @State private var appeared = false

    private var doneCount: Int { tasks.filter(\.done).count }
    private var allDone: Bool { !tasks.isEmpty && doneCount == tasks.count }

    // Completed tasks first (each group keeping its own original relative
    // order — Array.sorted is stable) — so evenlySpacedAngles below always
    // gives them the first N slots starting at 12 o'clock. That way the
    // progress fill's arc always ends exactly at the boundary between the
    // completed cluster and what's left, instead of a proportional sweep
    // that doesn't actually land on any particular token. A task's token
    // slides to its new slot when it flips done (same animation that
    // already reacts to task.done below), which reads as it "joining" the
    // completed side rather than just changing color in place.
    private var orderedTasks: [KidTask] {
        tasks.sorted { $0.done && !$1.done }
    }

    // One slot per task, evenly spaced around the full 360° starting at 12
    // o'clock — no longer tied to due time at all, so this never needs to
    // resolve collisions the way the old clock-position layout did.
    private var evenlySpacedAngles: [(task: KidTask, angle: Double)] {
        guard !tasks.isEmpty else { return [] }
        let step = 360.0 / Double(tasks.count)
        return orderedTasks.enumerated().map { index, task in
            (task, Double(index) * step - 90)
        }
    }

    // DeviceActivityMonitor only reports usage once a day, so this screen
    // deliberately never implies a live-ticking countdown — everything here
    // is driven by task completion (an explicit, in-app event), not by a
    // timer. That also means "0 done" needs its own honest, encouraging
    // copy rather than reading like a stalled/broken 0%.
    private var headerSubtitle: String {
        if tasks.isEmpty { return "No tasks today" }
        if allDone { return "Every task done! 🎉" }
        if doneCount == 0 { return "Let's get started, \(TabletData.child.name)!" }
        return "\(doneCount) of \(tasks.count) done"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    Text("Ring").font(Typography.display(28, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    Spacer()
                    Text(headerSubtitle)
                        .font(Typography.font(13, weight: .bold))
                        .foregroundStyle(KidTheme.greenDeep)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.7))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 20).padding(.top, 10)

                Spacer(minLength: 0)
                clockView
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A warm, glowing gradient instead of the flat sage app
            // background — this screen is meant to feel like a bright,
            // energetic reward, not another neutral utility page.
            .background(
                RadialGradient(
                    colors: [Color(hex: "CFF2DA"), Color(hex: "FFF3C4"), KidTheme.background],
                    center: .top,
                    startRadius: 30,
                    endRadius: 560
                )
                .ignoresSafeArea()
            )
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { appeared = true }
        }
    }

    // MARK: - Ring geometry

    private let diameter: CGFloat = 240
    private let tokenSize: CGFloat = 50

    private var clockView: some View {
        let outer = diameter + tokenSize + 20
        return ZStack {
            dialFace
            progressFill
            ForEach(Array(evenlySpacedAngles.enumerated()), id: \.element.task.id) { i, entry in
                taskToken(entry.task, angle: entry.angle, index: i)
            }
            centerContent
        }
        .frame(width: outer, height: outer)
    }

    private var dialFace: some View {
        Circle()
            .fill(.white.opacity(0.6))
            .frame(width: diameter - tokenSize * 0.6, height: diameter - tokenSize * 0.6)
            .blur(radius: 2)
            .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
            .overlay(
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: diameter, height: diameter)
                    .opacity(0.9)
            )
    }

    // The dial used to only report progress via the center "2/5" number —
    // asked for explicitly: the ring itself should visibly fill up as tasks
    // complete, not just the label inside it.
    private var progress: Double { tasks.isEmpty ? 0 : Double(doneCount) / Double(tasks.count) }

    private var progressFill: some View {
        Circle()
            .trim(from: 0, to: appeared ? progress : 0)
            .stroke(KidTheme.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(-90))
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
            .animation(.easeOut(duration: 0.6).delay(0.3), value: appeared)
    }

    private func taskToken(_ task: KidTask, angle deg: Double, index: Int) -> some View {
        let radians = deg * .pi / 180
        let resting = CGSize(width: cos(radians) * diameter / 2, height: sin(radians) * diameter / 2)

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(task.done ? KidTheme.green : .white)
                    .overlay(Circle().strokeBorder(task.done ? KidTheme.green : KidTheme.line, lineWidth: 2))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                Image(systemName: task.done ? "checkmark" : TabletData.sfIcon(for: task.iconTaskId))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(task.done ? .white : KidTheme.greenDeep)
            }
            .frame(width: tokenSize, height: tokenSize)

            // Evenly-spaced position no longer says anything about when a
            // task is due, so the due time rides along as its own small
            // label instead — restores that at-a-glance info without going
            // back to a layout where it was implied by placement alone.
            if let due = task.due {
                Text(due)
                    .font(Typography.font(9.5, weight: .bold))
                    .foregroundStyle(KidTheme.inkSoft)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
        .offset(appeared ? resting : .zero)
        .scaleEffect(appeared ? 1 : 0.2)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.55, dampingFraction: 0.7).delay(Double(index) * 0.06),
            value: appeared
        )
        // Redone/completed after the initial assembly still gets its own
        // little pop rather than waiting on the (already-fired) stagger —
        // also what animates a token sliding into its new slot when
        // orderedTasks regroups it into the completed cluster.
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: task.done)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: deg)
    }

    private var centerContent: some View {
        VStack(spacing: 4) {
            if allDone {
                Text("🎉").font(.system(size: 34))
                Text("All done!").font(Typography.display(18, weight: .heavy)).foregroundStyle(KidTheme.ink)
            } else {
                Text("\(doneCount)/\(tasks.count)")
                    .font(Typography.display(36, weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                Text(doneCount == 0 ? "Let's start!" : "tasks done")
                    .font(Typography.font(12, weight: .semibold))
                    .foregroundStyle(KidTheme.inkSoft)
            }
        }
    }
}
