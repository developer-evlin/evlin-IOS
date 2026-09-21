import SwiftUI

struct ScreenHome: View {
    @Environment(SessionManager.self) private var session

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
        var taskId: String
        var id: String { "\(childId)-\(taskId)" }
    }
    // FamilyStore.children is a static mock array, not @Published — bumping
    // this on appear is what makes Home pick up a child added/removed from
    // Settings instead of showing a stale screen from its last render.
    @State private var familyRefreshTick = 0

    private var unreadCount: Int { NotificationsData.notifs.filter(\.unread).count }

    var body: some View {
        // Re-evaluate (and re-read FamilyStore.children, so a name the child
        // typed while pairing shows up) whenever a backend sync completes.
        let _ = SyncState.shared.version
        NavigationStack {
            Group {
                // Onboarding always produces exactly one child before
                // ParentRootView (and therefore Home) ever renders, so this
                // is Home's entire content — no picker to choose between,
                // no fullScreenCover to hide the tab bar behind. Settings'
                // "Add a child" can add more later (multi-child support
                // isn't gone), but that's a deliberate opt-in, not the
                // default onboarding output this screen needs to plan for.
                if let onlyChild = FamilyStore.children.first {
                    ScreenProfile(
                        childId: onlyChild.id,
                        onBack: {},
                        hideBackButton: true
                    )
                } else {
                    // Not normally reachable — onboarding creates the child
                    // before this screen can ever appear — but Settings lets
                    // a parent remove their only child, so this needs a real
                    // state instead of force-unwrapping into a crash.
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 40)).foregroundStyle(EColor.onSurfaceVariant)
                        Text("No child yet").font(Typography.font(17, weight: .heavy)).foregroundStyle(EColor.onSurface)
                        Text("Add a child from Settings to get started.")
                            .font(Typography.font(13, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(EColor.surface)
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
            // A kid can finish pairing (and type their name) at any time on
            // their own device, so poll while Home is visible instead of only
            // syncing at launch/onboarding.
            .task {
                while !Task.isCancelled {
                    await AppSync.shared.syncBackendData()
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
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
                childId: target.childId,
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
                ScreenProfile(childId: wrapped.value, onBack: { openChildId = nil })
            }
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
    var onOpenChild: (String, String?) -> Void
    @State private var notifs = NotificationsData.notifs
    @Environment(\.dismiss) private var dismiss

    // No per-child color mapping exists (children only ever have real
    // backend UUIDs) — this just tints every notification the same until
    // there's a real reason to tell children apart here.
    private func color(for childId: String) -> Color { EColor.primary }

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
