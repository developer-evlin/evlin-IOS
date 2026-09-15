import SwiftUI

struct ScreenHome: View {
    @Binding var taskTutorialDone: Bool
    @State private var showNotifs = false
    @State private var openChildId: String?
    // A notification naming a specific task used to only ever get there via
    // openChildId + openTaskId together, which opened ScreenProfile first
    // and had *it* immediately push TaskReviewDeckView on top — two stacked
    // slide-up transitions back to back, reading as "profile, then task"
    // instead of landing on the task directly. This presents the review
    // deck straight from Home instead; Profile still opens once it's
    // dismissed (see the fullScreenCover below), so backing out of the task
    // still lands the parent on that child's profile same as before.
    @State private var directReview: DirectReviewTarget?

    private struct DirectReviewTarget: Identifiable {
        var childId: String
        var taskId: Int
        var id: String { "\(childId)-\(taskId)" }
    }
    // Fires once per Home appearance (not tied to taskTutorialDone) so
    // parents land straight on their first child's profile by default,
    // without permanently trapping them there — after this first auto-open,
    // tapping back returns to the profile-picker grid normally.
    @State private var didAutoOpen = false
    // FamilyStore.children is a static mock array, not @Published — bumping
    // this on appear is what makes Home pick up a child added/removed from
    // Settings instead of showing a stale grid from its last render.
    @State private var familyRefreshTick = 0
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var adaptive: ParentAdaptive { ParentAdaptive(hSizeClass) }

    private var unreadCount: Int { NotificationsData.notifs.filter(\.unread).count }

    var body: some View {
        NavigationStack {
            Group {
                // Demo-only preview: with exactly one child there's nothing
                // to actually choose between, so tapping a single bubble
                // just to get where you're already headed is a pointless
                // extra step. Home becomes that child's own space directly
                // instead — and because this still lives inline in Home's
                // own NavigationStack rather than behind the usual
                // fullScreenCover (see openChildId below), the app's
                // persistent tab bar stays visible under it, unlike the
                // normal multi-child flow where the covering profile hides
                // the tab bar entirely.
                if FamilyStore.children.count == 1, let onlyChild = FamilyStore.children.first {
                    ScreenProfile(
                        childId: onlyChild.id,
                        onBack: {},
                        hideBackButton: true,
                        startInTutorial: !taskTutorialDone,
                        onTutorialCompleted: { taskTutorialDone = true }
                    )
                } else {
                    ZStack {
                        EColor.surface.ignoresSafeArea()

                        VStack {
                            // A single Spacer above only, not one on both sides —
                            // two flexible Spacers around a short, fixed-size grid
                            // read fine on an iPhone's short screen (grid sits a
                            // beat above true center) but on an iPad's much taller
                            // canvas both absorb all the extra height and strand a
                            // handful of small circles adrift in a sea of blank
                            // space with no visual anchor. Pinning the grid nearer
                            // the top instead reads as a deliberate page of
                            // profiles, not a phone screen floating in the middle
                            // of a bigger one.
                            if !adaptive.isRegular { Spacer() }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: adaptive.of(96, 132), maximum: adaptive.of(108, 150)), spacing: adaptive.of(18, 28))],
                                spacing: adaptive.of(18, 28)
                            ) {
                                ForEach(FamilyStore.children) { child in
                                    ProfileBubble(child: child, adaptive: adaptive) { openChildId = child.id }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, adaptive.isRegular ? 32 : 0)
                            .parentContentColumn(adaptive.isRegular ? 960 : nil)
                            if !adaptive.isRegular { Spacer(); Spacer() }
                        }
                    }
                }
            }
            // Same bug as ScreenSettings' own familyRefreshTick: bumping it
            // here did nothing on its own — nothing in this Group's content
            // actually read it, so SwiftUI had no reason to think the
            // FamilyStore.children-derived grid/single-child branch above
            // had gone stale. Keying the whole Group on it forces a fresh
            // rebuild (and a fresh read of FamilyStore.children) every time
            // Home reappears, instead of only catching up whenever some
            // other unrelated state change happened to force a re-render.
            .id(familyRefreshTick)
            .onAppear { familyRefreshTick += 1 }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    homeBrandMark
                }
                // Just notifications now — this used to also carry a gear
                // icon that, despite looking like Settings, actually
                // switched modes (back to the Parent/Child picker). That
                // conflated two unrelated things under one icon; Settings is
                // its own dedicated tab below (Telegram-style: Settings is
                // its own place, not a shortcut bolted onto Home), and
                // "leave this mode" now lives inside it as Sign Out.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNotifs = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill").foregroundStyle(EColor.onSurface)
                            if unreadCount > 0 {
                                Circle().fill(EColor.danger).frame(width: 8, height: 8).offset(x: 3, y: -3)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showNotifs) {
            NotificationPanel(onOpenChild: { id, taskId in
                showNotifs = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // A real task to jump to goes straight to the review
                    // deck; a notification with no task behind it (e.g. a
                    // plain reminder) still falls back to opening the
                    // profile the same way it always did.
                    if let taskId {
                        directReview = DirectReviewTarget(childId: id, taskId: taskId)
                    } else {
                        openChildId = id
                    }
                }
            })
        }
        .fullScreenCover(item: $directReview) { target in
            TaskReviewDeckView(
                tasks: TaskStore.binding(for: target.childId),
                childName: FamilyStore.child(target.childId).name,
                startIndex: TaskStore.tasks(for: target.childId).firstIndex(where: { $0.id == target.taskId }) ?? 0,
                onDismiss: {
                    directReview = nil
                    openChildId = target.childId
                }
            )
        }
        // fullScreenCover, not .sheet — on iPad a .sheet presents as a small
        // centered card by default; this is a real screen, not a modal.
        .fullScreenCover(item: Binding(get: { openChildId.map { IdentifiedString(value: $0) } }, set: { openChildId = $0?.value })) { wrapped in
            NavigationStack {
                ScreenProfile(
                    childId: wrapped.value,
                    onBack: { openChildId = nil },
                    startInTutorial: !taskTutorialDone && wrapped.value == FamilyStore.children.first?.id,
                    onTutorialCompleted: { taskTutorialDone = true }
                )
            }
        }
        .task {
            // The single-child demo path above already shows that child's
            // profile inline — auto-opening it a second time here as a
            // fullScreenCover on top of itself would just be a pointless
            // covering duplicate.
            guard FamilyStore.children.count != 1 else { return }
            guard !didAutoOpen, let first = FamilyStore.children.first else { return }
            didAutoOpen = true
            // Same beat NotificationPanel's onOpenChild already uses below —
            // setting openChildId in the same transaction as this view's
            // first appearance gives fullScreenCover no "before" frame to
            // animate from, so it just pops in instantly instead of
            // sliding up like every other profile open.
            try? await Task.sleep(nanoseconds: 100_000_000)
            openChildId = first.id
        }
    }

    private var homeBrandMark: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 9).fill(EColor.primary).frame(width: 30, height: 30)
                .overlay(Image(systemName: "flame.fill").font(.system(size: 14)).foregroundStyle(Color(hex: "8CE6A8")))
            Text("Evlin").font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
        }
    }
}

struct IdentifiedString: Identifiable { var value: String; var id: String { value } }

// Netflix-style profile "bubble" — big circular avatar + name.
private struct ProfileBubble: View {
    @ObservedObject var child: Child
    var adaptive: ParentAdaptive
    var onTap: () -> Void

    private var statusText: String {
        if let r = child.reflection { return "Reflection · \(r.minutes)m" }
        switch child.status {
        case .unlocked: return child.timeLeft
        case .lockedTasks: return "\(child.tasksDone)/\(child.tasksTotal) tasks"
        case .locked: return "Locked"
        case .downtime: return "Downtime · \(child.downtimeUntil ?? "")"
        }
    }

    private var statusColor: Color {
        if child.reflection != nil { return Color(hex: "6E4F26") }
        switch child.status {
        case .unlocked: return Color(hex: "25924A")
        case .lockedTasks: return EColor.danger
        case .locked: return EColor.onSurfaceVariant
        case .downtime: return downtimeIndigo
        }
    }

    // Fixed brand green rather than the child's own avatar color (which
    // varies per kid) — "time remaining" reads as one consistent signal
    // across every card instead of doubling as a second, redundant use of
    // each kid's identity color.
    private var barColor: Color { child.status == .unlocked ? Color(hex: "25924A") : Color(hex: "CBD5E1") }

    // "Time pool" — dailyLimitMin split into 30-min blocks (a trailing
    // partial block absorbs the remainder, e.g. 1h45m -> 3×30 + 1×15), each
    // lit up if it falls within the child's remaining allowance
    // (timePct, the *unused* portion per FamilyData's doc comment). Locked
    // states show the same block structure fully unlit, matching the old
    // plain-gray ring's "nothing available right now" read.
    private var timePoolFilledMinutes: Int {
        guard child.status == .unlocked else { return 0 }
        return Int((Double(child.dailyLimitMin) * Double(child.timePct) / 100).rounded())
    }

    // Downtime gets a crescent moon, not a padlock — this badge names WHY
    // the phone is locked, and a schedule lock isn't a manual one.
    private var badgeIcon: String {
        if child.reflection != nil { return "figure.mind.and.body" }
        if child.status == .downtime { return "moon.fill" }
        return "lock.fill"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: adaptive.of(10, 14)) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(child.color)
                        .frame(width: adaptive.of(92, 128), height: adaptive.of(92, 128))
                        .overlay(Text(String(child.name.prefix(1))).font(Typography.font(adaptive.of(36, 50), weight: .heavy)).foregroundStyle(.white))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    if child.status != .unlocked {
                        Circle().fill(.white).frame(width: adaptive.of(26, 34), height: adaptive.of(26, 34))
                            .overlay(Image(systemName: badgeIcon).font(.system(size: adaptive.of(13, 17))).foregroundStyle(statusColor))
                            .shadow(color: .black.opacity(0.18), radius: 3)
                    }
                }
                VStack(spacing: 1) {
                    Text(child.name).font(Typography.font(adaptive.of(15, 19), weight: .heavy)).foregroundStyle(child.color)
                    Text(statusText.uppercased()).font(Typography.font(adaptive.of(10, 12), weight: .bold)).tracking(0.6).foregroundStyle(statusColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// The child's daily allowance split into discrete 30-minute blocks (a
// trailing partial block covers any remainder, e.g. 105min -> three 30s +
// one 15), laid out as a row of short bars rather than one continuous
// progress fill — replaces the old SegmentedTimeRing (the ring drawn around
// the avatar, dropped entirely: the rounded end-caps on adjacent arc
// segments read as stray notches/seams around the circle rather than a
// deliberate partitioned look). Not private — ScreenProfile's headerCard
// reuses this for the same child so the "how many half-hours are left"
// read is identical on the family grid and on a single kid's own profile.
struct SegmentedTimeBar: View {
    var totalMinutes: Int
    var filledMinutes: Int
    var filledColor: Color
    var emptyColor: Color

    private let blockMinutes = 30
    private let creditMinutes = 15

    // The pool only ever moves in 30-min blocks, and a block only counts
    // once you're at least 15 minutes into it — floor to that 15-min mark
    // rather than filling proportionally to the exact minute, so a block
    // only ever reads as empty, half, or full, never some arbitrary sliver
    // in between (e.g. 81 of 90 minutes used to render as a 70%-filled
    // segment; now it reads as a clean half-filled one).
    private var quantizedFilledMinutes: Int {
        (filledMinutes / creditMinutes) * creditMinutes
    }

    // Still quantized to 30-min blocks — the fill snaps to the nearest
    // block boundary rather than an exact percentage — but rendered with no
    // gap between them and square inner edges, so adjacent same-colored
    // blocks fuse into one continuous run and the whole thing reads as a
    // single bar, not a row of separate pills.
    private var blocks: [Int] {
        guard totalMinutes > 0 else { return [] }
        var blocks: [Int] = []
        var remaining = totalMinutes
        while remaining >= blockMinutes {
            blocks.append(blockMinutes)
            remaining -= blockMinutes
        }
        if remaining > 0 { blocks.append(remaining) }
        return blocks
    }

    private let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            // A hairline gap between blocks — visible as a thin partition
            // mark, not a break in the bar, since only the two outer ends
            // get rounded (below): the seams read as divider ticks inside
            // one continuous pill, not as separate floating segments.
            let totalGap = gap * CGFloat(max(blocks.count - 1, 0))
            let availableWidth = max(geo.size.width - totalGap, 0)
            HStack(spacing: gap) {
                let cumulative: [Int] = blocks.reduce(into: []) { acc, m in acc.append((acc.last ?? 0) + m) }
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, minutes in
                    let blockStart = index == 0 ? 0 : cumulative[index - 1]
                    let blockEnd = cumulative[index]
                    let width = availableWidth * CGFloat(minutes) / CGFloat(totalMinutes)
                    // Fractional fill within the boundary block — e.g. a
                    // 15-min grant against a 30-min block lights up half of
                    // it, instead of the old all-or-nothing rule where any
                    // amount short of the whole block showed as fully empty.
                    // Built on the quantized value, not the raw one, so this
                    // only ever lands on 0, 0.5, or 1 within a block.
                    let fillFraction: CGFloat = {
                        if quantizedFilledMinutes >= blockEnd { return 1 }
                        if quantizedFilledMinutes <= blockStart { return 0 }
                        return CGFloat(quantizedFilledMinutes - blockStart) / CGFloat(blockEnd - blockStart)
                    }()
                    ZStack(alignment: .leading) {
                        Rectangle().fill(emptyColor)
                        Rectangle().fill(filledColor).frame(width: width * fillFraction)
                    }
                    .frame(width: width)
                }
            }
            .clipShape(Capsule())
        }
    }
}

private struct NotificationPanel: View {
    var onOpenChild: (String, Int?) -> Void
    @State private var notifs = NotificationsData.notifs
    @Environment(\.dismiss) private var dismiss

    private func color(for childId: String) -> Color {
        switch childId {
        case "liam": return Color(hex: "2563EB")
        case "maya": return Color(hex: "3DAA5C")
        case "emma": return Color(hex: "F97316")
        default: return EColor.primary
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(notifs) { n in
                    Button {
                        if let i = notifs.firstIndex(where: { $0.id == n.id }) { notifs[i].unread = false }
                        if n.child != "family" { onOpenChild(n.child, n.taskId) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            if n.unread {
                                Circle().fill(color(for: n.child)).frame(width: 6, height: 6).padding(.top, 6)
                            } else {
                                Color.clear.frame(width: 6, height: 6)
                            }
                            Image(systemName: EIcon.sf(n.icon))
                                .font(.system(size: 18))
                                .foregroundStyle(color(for: n.child))
                                .frame(width: 40, height: 40)
                                .background(color(for: n.child).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(n.title).font(Typography.font(13, weight: .heavy)).foregroundStyle(EColor.primary)
                                    Spacer()
                                    Text(n.time).font(Typography.font(10, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                                }
                                Text(n.body).font(Typography.font(12, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(n.unread ? color(for: n.child).opacity(0.05) : Color.clear)
                }
                .onDelete { idx in notifs.remove(atOffsets: idx) }
            }
            .listStyle(.plain)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark all read") { for i in notifs.indices { notifs[i].unread = false } }
                        .font(Typography.font(12, weight: .semibold))
                }
            }
        }
    }
}
