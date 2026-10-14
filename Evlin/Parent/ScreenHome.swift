import SwiftUI

struct ScreenHome: View {
    @Environment(SessionManager.self) private var session

    @State private var showNotifs = false
    // A notification naming a specific task opens the review deck straight
    // from Home; closing it leaves Home showing that child.
    @State private var directReview: DirectReviewTarget?

    private struct DirectReviewTarget: Identifiable {
        var childId: String
        var taskId: String
        // The tasks the deck swipes through, fixed when it opens (see
        // TaskStore.reviewGroup). Empty for a task that isn't today's.
        var group: [String]
        var id: String { "\(childId)-\(taskId)" }
    }
    // FamilyStore.children is a static mock array, not @Published — bumping
    // this on appear is what makes Home pick up a child added/removed from
    // Settings instead of showing a stale screen from its last render.
    @State private var familyRefreshTick = 0
    // Set by a child's page while one of its cards (unlock confirm, extra
    // time, …) is up; see headerScrim.
    @State private var pageScrim: Double = 0

    private var unreadCount: Int { NotificationsData.notifs.filter(\.unread).count }

    var body: some View {
        // Re-evaluate (and re-read FamilyStore.children, so a name the child
        // typed while pairing shows up) whenever a backend sync completes.
        let _ = SyncState.shared.version
        // Re-read FamilyStore.children each time Home appears, so a child
        // removed in Settings is gone (removal doesn't run a sync).
        let _ = familyRefreshTick
        NavigationStack {
            Group {
                if FamilyStore.children.isEmpty && !SyncState.shared.hasFinishedFirstSync {
                    // Still loading on a cold launch: the children arrive
                    // with the first sync, so this isn't "no child" yet.
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if FamilyStore.children.isEmpty {
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
                } else {
                    VStack(spacing: 0) {
                        header
                            .overlay { headerScrim }
                        childPages
                    }
                    .onPreferenceChange(HomeScrimKey.self) { value in
                        withAnimation(.easeOut(duration: 0.2)) { pageScrim = value }
                    }
                }
            }
            .background(EColor.surface)
            // Only re-reads (see the top of body). It used to key the whole
            // page on the counter with .id, rebuilding the child's page and
            // throwing away anything open on it every time Home appeared.
            .onAppear { familyRefreshTick += 1 }
            // The header below is Home's own top bar.
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showNotifs) {
            Group {
            NotificationPanel(onOpenChild: { id, taskId in
                showNotifs = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // A real task to jump to goes straight to the review
                    // deck; a notification with no task behind it (e.g. a
                    // plain reminder) still falls back to opening the
                    // profile the same way it always did.
                    session.activeChildId = id
                    if let taskId {
                        directReview = DirectReviewTarget(childId: id, taskId: taskId,
                                                          group: TaskStore.reviewGroup(for: id, startingAt: taskId))
                    }
                }
            })
        }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $directReview) { target in
            // Swipes through the tapped task's own group: the tasks still
            // needing something, or today's completed ones, never both and
            // never other days. A notification about a task that isn't
            // today's opens just that task.
            let ids = target.group.isEmpty ? [target.taskId] : target.group
            TaskReviewDeckView(
                taskIds: ids,
                childName: FamilyStore.child(target.childId).name,
                childId: target.childId,
                startIndex: ids.firstIndex(of: target.taskId) ?? 0,
                onDismiss: { directReview = nil }
            )
        }
    }

    // Every review deck opens from here, one level above the child's page:
    // a deck presented from inside the page was rebuilt each time the page
    // redrew, which threw away the edit sheet the moment it opened.
    private func review(_ childId: String, _ taskId: String) {
        directReview = DirectReviewTarget(childId: childId, taskId: taskId,
                                          group: TaskStore.reviewGroup(for: childId, startingAt: taskId))
    }

    // The selected child, falling back to the first if the stored choice
    // is gone (removed, or not synced yet).
    private var selectedChild: Child? {
        FamilyStore.children.first { $0.id == session.activeChildId } ?? FamilyStore.children.first
    }

    // The same backdrop a card puts over the page, continued over the header
    // and up under the status bar, so the whole screen dims as one. It also
    // takes the header's taps while a card is up, like the page's backdrop.
    @ViewBuilder private var headerScrim: some View {
        if pageScrim > 0 {
            Color.black.opacity(pageScrim)
                .ignoresSafeArea(edges: .top)
                .contentShape(Rectangle())
                .onTapGesture {}
                .transition(.opacity)
        }
    }

    private var parentFirstName: String {
        let name = ParentProfile.shared.displayName.trimmingCharacters(in: .whitespaces)
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    // The design's header: every child's avatar on the right (with two or
    // more), then the greeting with notifications beside it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only with more than one child: the avatars are how a parent
            // switches between them, and with one child they just take a row.
            if FamilyStore.children.count > 1 {
                HStack {
                    Spacer()
                    childAvatars
                }
            }
            HStack(alignment: .center) {
                Text(parentFirstName.isEmpty ? "Hi there" : "Hi, \(parentFirstName)")
                    .font(Typography.font(32, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                // Just notifications: Settings is its own tab, and "leave
                // this mode" lives inside it as Sign Out.
                Button { showNotifs = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(HomeStyle.green)
                            .frame(width: 40, height: 40)
                        if unreadCount > 0 {
                            Circle().fill(HomeStyle.red).frame(width: 8, height: 8).offset(x: -8, y: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(unreadCount > 0 ? "Notifications, \(unreadCount) unread" : "Notifications")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // Two letters per child on a tint of their colour. The selected one is a
    // little larger with a ring; the others fade back. The amber badge counts
    // what that child has sent in for review, so a parent sees who needs
    // them without switching.
    private var childAvatars: some View {
        HStack(spacing: 6) {
            ForEach(FamilyStore.children, id: \.id) { child in
                let selected = child.id == selectedChild?.id
                let waiting = TaskStore.tasks(for: child.id).filter { $0.isDueToday && ($0.state == .review || $0.state == .bypass) }.count
                Button {
                    withAnimation(.snappy(duration: 0.3)) { session.activeChildId = child.id }
                } label: {
                    Text(String(child.name.prefix(2)).uppercased())
                        .font(Typography.font(11, weight: .heavy))
                        .foregroundStyle(child.color)
                        .frame(width: 32, height: 32)
                        .background(child.color.opacity(0.14), in: Circle())
                        .overlay(Circle().strokeBorder(EColor.surface, lineWidth: 2))
                        .overlay(Circle().strokeBorder(selected ? child.color : .clear, lineWidth: 2).padding(-2))
                        .scaleEffect(selected ? 1.14 : 1)
                        .opacity(selected ? 1 : 0.45)
                        .overlay(alignment: .topTrailing) {
                            if waiting > 0 {
                                Text("\(waiting)")
                                    .font(Typography.font(9.5, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(HomeStyle.amber, in: Capsule())
                                    .overlay(Capsule().strokeBorder(EColor.surface, lineWidth: 2))
                                    .offset(x: 6, y: -6)
                            }
                        }
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(child.name)
                .accessibilityValue(waiting > 0 ? "\(waiting) to review" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // One page per child, picked with the avatars above.
    // Not a sideways pager: on Home a sideways swipe switches Today and
    // Tomorrow.
    @ViewBuilder private var childPages: some View {
        if let child = selectedChild {
            VStack(spacing: 0) {
                ScreenProfile(childId: child.id, onReview: { review(child.id, $0) })
                    .id(child.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: child.id)
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
