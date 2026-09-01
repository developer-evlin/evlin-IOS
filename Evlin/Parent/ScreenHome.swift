import SwiftUI

struct ScreenHome: View {
    var onSwitchMode: () -> Void
    @Binding var taskTutorialDone: Bool
    @State private var showNotifs = false
    @State private var openChildId: String?
    // Fires once per Home appearance (not tied to taskTutorialDone) so
    // parents land straight on their first child's profile by default,
    // without permanently trapping them there — after this first auto-open,
    // tapping back returns to the profile-picker grid normally.
    @State private var didAutoOpen = false
    // FamilyStore.children is a static mock array, not @Published — bumping
    // this on appear is what makes Home pick up a child added/removed from
    // Settings instead of showing a stale grid from its last render.
    @State private var familyRefreshTick = 0

    private var unreadCount: Int { NotificationsData.notifs.filter(\.unread).count }

    var body: some View {
        NavigationStack {
            ZStack {
                EColor.surface.ignoresSafeArea()

                VStack {
                    Spacer()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 108), spacing: 18)], spacing: 18) {
                        ForEach(FamilyStore.children) { child in
                            ProfileBubble(child: child) { openChildId = child.id }
                        }
                    }
                    .padding(.horizontal, 24)
                    Spacer()
                    Spacer()
                }
            }
            .onAppear { familyRefreshTick += 1 }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 9).fill(EColor.primary).frame(width: 30, height: 30)
                            .overlay(Image(systemName: "flame.fill").font(.system(size: 14)).foregroundStyle(Color(hex: "8CE6A8")))
                        Text("Evlin").font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button { showNotifs = true } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bell.fill").foregroundStyle(EColor.onSurface)
                                if unreadCount > 0 {
                                    Circle().fill(EColor.danger).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                }
                            }
                        }
                        Button { onSwitchMode() } label: {
                            Image(systemName: "gearshape.fill").foregroundStyle(EColor.onSurface)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showNotifs) {
            NotificationPanel(onOpenChild: { id in
                showNotifs = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { openChildId = id }
            })
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
            guard !didAutoOpen, let first = FamilyStore.children.first else { return }
            didAutoOpen = true
            openChildId = first.id
        }
    }
}

struct IdentifiedString: Identifiable { var value: String; var id: String { value } }

// Netflix-style profile "bubble" — big circular avatar + name.
private struct ProfileBubble: View {
    @ObservedObject var child: Child
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
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(child.color)
                        .frame(width: 92, height: 92)
                        .overlay(Text(String(child.name.prefix(1))).font(Typography.font(36, weight: .heavy)).foregroundStyle(.white))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    if child.status != .unlocked {
                        Circle().fill(.white).frame(width: 26, height: 26)
                            .overlay(Image(systemName: badgeIcon).font(.system(size: 13)).foregroundStyle(statusColor))
                            .shadow(color: .black.opacity(0.18), radius: 3)
                    }
                }
                VStack(spacing: 1) {
                    Text(child.name).font(Typography.font(15, weight: .heavy)).foregroundStyle(child.color)
                    Text(statusText.uppercased()).font(Typography.font(10, weight: .bold)).tracking(0.6).foregroundStyle(statusColor)
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
                    let fillFraction: CGFloat = {
                        if filledMinutes >= blockEnd { return 1 }
                        if filledMinutes <= blockStart { return 0 }
                        return CGFloat(filledMinutes - blockStart) / CGFloat(blockEnd - blockStart)
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
    var onOpenChild: (String) -> Void
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
                        if n.child != "family" { onOpenChild(n.child) }
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
