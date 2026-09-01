import SwiftUI

// The kid-side "Ring" tab (formerly "Skill Map") — a literal clock face: each
// task's icon sits on the dial at the hour position matching its deadline
// (same idea as numbers on a real clock, just task icons instead of digits),
// so a glance at the shape of the day shows not just how many tasks are left
// but roughly when they land. Tasks without a deadline don't get a spot on
// the dial (there's no honest place to put them) — they collect in a small
// "Anytime" row below it instead. On first appearance every token starts
// collapsed at the center and springs out to its clock position, staggered
// by due time, so the dial visibly "assembles itself" rather than just
// being there.
struct ScreenRing: View {
    var tasks: [KidTask]

    @State private var appeared = false

    private var doneCount: Int { tasks.filter(\.done).count }
    private var allDone: Bool { !tasks.isEmpty && doneCount == tasks.count }

    // Timed tasks sorted by clock position so the stagger-in animation
    // sweeps around the dial in order rather than in list order.
    private var timedTasks: [KidTask] {
        tasks.filter { $0.due != nil }.sorted { (angle(for: $0.due) ?? 0) < (angle(for: $1.due) ?? 0) }
    }
    private var anytimeTasks: [KidTask] { tasks.filter { $0.due == nil } }

    // A real school day's tasks tend to cluster within the same few evening
    // hours, and a 30°-per-hour dial doesn't leave much room for that — two
    // tasks even half an hour apart land only 15° apart, well under the
    // ~28-30° two 50pt tokens need at this radius to not physically overlap.
    // This sweeps the (already angle-sorted) timed tasks forward, nudging
    // each one just far enough past the last to clear it — the clock face
    // and hand underneath are untouched, only where tokens actually sit
    // changes, and only when they'd otherwise collide.
    private var timedTaskAngles: [(task: KidTask, angle: Double)] {
        let minSeparation: Double = 30
        var placed: [(task: KidTask, angle: Double)] = []
        for task in timedTasks {
            let natural = angle(for: task.due) ?? 0
            let deg = placed.last.map { max(natural, $0.angle + minSeparation) } ?? natural
            placed.append((task, deg))
        }
        return placed
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
                if !anytimeTasks.isEmpty {
                    anytimeRow
                        .padding(.top, 18)
                }
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

    // MARK: - Clock geometry

    private let diameter: CGFloat = 240
    private let tokenSize: CGFloat = 50

    // Maps a "h:mm a" due string onto a 12-hour dial, degrees clockwise from
    // 12 o'clock (top = -90° in standard math convention, so 0° there reads
    // as 3 o'clock — the -90 offset below corrects for that).
    private func angle(for due: String?) -> Double? {
        guard let due else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let time = formatter.date(from: due) else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = Double(comps.hour ?? 0).truncatingRemainder(dividingBy: 12)
        let minute = Double(comps.minute ?? 0)
        let hourPosition = hour + minute / 60
        return hourPosition / 12 * 360 - 90
    }

    private var currentAngle: Double {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour = Double(comps.hour ?? 0).truncatingRemainder(dividingBy: 12)
        let minute = Double(comps.minute ?? 0)
        return (hour + minute / 60) / 12 * 360 - 90
    }

    private var clockView: some View {
        let outer = diameter + tokenSize + 20
        return ZStack {
            dialFace
            progressFill
            hourTicks
            currentTimeHand
            ForEach(Array(timedTaskAngles.enumerated()), id: \.element.task.id) { i, entry in
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

    // 12 small tick marks, like an analog clock's hour markers, so the
    // "this is a clock" read is legible even before any tasks are placed.
    private var hourTicks: some View {
        ForEach(0..<12, id: \.self) { hour in
            Capsule()
                .fill(KidTheme.inkSoft.opacity(0.35))
                .frame(width: 3, height: 10)
                .offset(y: -diameter / 2 + 5)
                .rotationEffect(.degrees(Double(hour) / 12 * 360))
        }
    }

    // Slowly-updating "where we are right now" hand — TimelineView, not a
    // manual Timer, so it costs nothing while this tab isn't visible.
    private var currentTimeHand: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let radians = currentAngle * .pi / 180
            Capsule()
                .fill(Color(hex: "DB9A00"))
                .frame(width: 3, height: diameter / 2 - 16)
                .offset(y: -(diameter / 4 - 8))
                .rotationEffect(.radians(radians + .pi / 2))
                .opacity(appeared ? 0.8 : 0)
        }
    }

    private func taskToken(_ task: KidTask, angle deg: Double, index: Int) -> some View {
        let radians = deg * .pi / 180
        let resting = CGSize(width: cos(radians) * diameter / 2, height: sin(radians) * diameter / 2)

        return ZStack {
            Circle()
                .fill(task.done ? KidTheme.green : .white)
                .overlay(Circle().strokeBorder(task.done ? KidTheme.green : KidTheme.line, lineWidth: 2))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Image(systemName: task.done ? "checkmark" : TabletData.sfIcon(for: task.iconTaskId))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(task.done ? .white : KidTheme.greenDeep)
        }
        .frame(width: tokenSize, height: tokenSize)
        .offset(appeared ? resting : .zero)
        .scaleEffect(appeared ? 1 : 0.2)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.55, dampingFraction: 0.7).delay(Double(index) * 0.06),
            value: appeared
        )
        // Redone/completed after the initial assembly still gets its own
        // little pop rather than waiting on the (already-fired) stagger.
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: task.done)
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

    // MARK: - Anytime cluster

    // No deadline means no honest clock position — these get their own row
    // instead of being forced onto the dial somewhere misleading.
    private var anytimeRow: some View {
        VStack(spacing: 8) {
            Text("ANYTIME TODAY")
                .font(Typography.font(10.5, weight: .bold)).tracking(1)
                .foregroundStyle(KidTheme.inkSoft)
            HStack(spacing: 12) {
                ForEach(anytimeTasks) { task in
                    ZStack {
                        Circle()
                            .fill(task.done ? KidTheme.green : .white)
                            .overlay(Circle().strokeBorder(task.done ? KidTheme.green : KidTheme.line, lineWidth: 2))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                        Image(systemName: task.done ? "checkmark" : TabletData.sfIcon(for: task.iconTaskId))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(task.done ? .white : KidTheme.greenDeep)
                    }
                    .frame(width: 40, height: 40)
                    .scaleEffect(appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.4), value: appeared)
                }
            }
        }
    }
}
