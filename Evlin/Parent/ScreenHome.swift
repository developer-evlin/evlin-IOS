import SwiftUI

struct ScreenHome: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    // The child whose Screen time page is open (the hourglass).
    // A notification naming a specific task opens the review deck straight
    // from Home; closing it leaves Home showing that child.
    @State private var directReview: DirectReviewTarget?
    /// A child on the free plan's far side (the Demo's Leo): the plan page.
    @State private var proChild: Child?

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
        // Demo: `leopaywall` opens the plan page Leo's avatar opens.
        .task {
            guard DemoMode.parentOpen == "leopaywall",
                  let leo = FamilyStore.children.first(where: { EvlinPlan.needsPro(toOpen: $0.id) }) else { return }
            try? await Task.sleep(for: .seconds(0.6))
            session.activeChildId = leo.id
            proChild = leo
        }
        // Demo: `noahtrial` picks Noah, the trial with 3 days left.
        .task {
            guard ["noahtrial", "noahprofile"].contains(DemoMode.parentOpen ?? ""),
                  let noah = FamilyStore.children.first(where: { EvlinPlan.trialDaysLeft(on: $0.id) != nil }) else { return }
            try? await Task.sleep(for: .seconds(0.6))
            session.activeChildId = noah.id
            if DemoMode.parentOpen == "noahtrial" { proChild = noah }
        }
        // Demo: `review` opens Math homework, sent in without a photo.
        .task {
            guard DemoMode.parentOpen == "review", let child = FamilyStore.children.first else { return }
            try? await Task.sleep(for: .seconds(0.8))
            review(child.id, String(format: "22222222-2222-4222-8222-%012d", 3))
        }
        // The Demo's free-plan example (Leo): his page, with the
        // trial-ended card over it, then the plan page.
        .childTrialEnded($proChild, demoOpens: true) { c in
            withAnimation(.snappy(duration: 0.3)) { session.activeChildId = c.id }
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

    // One row at the top: every child's avatar (with two or more), on the
    // right. No greeting, no screen-time button (Profile shows screen time)
    // and no notifications: Home's own lanes show what needs the parent.
    private var header: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            // Only with more than one child: the avatars are how a parent
            // switches between them.
            if FamilyStore.children.count > 1 {
                childAvatars
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // Two letters per child on a tint of their colour. The selected one is a
    // little larger with a ring; the others fade back. The orange badge counts
    // what that child has sent in for review (tasks, and goal check-ins
    // from today), so a parent sees who needs them without switching.
    private var childAvatars: some View {
        HStack(spacing: 6) {
            ForEach(FamilyStore.children, id: \.id) { child in
                let selected = child.id == selectedChild?.id
                let waiting = TaskStore.tasks(for: child.id).filter { $0.isDueToday && ($0.state == .review || $0.state == .bypass) }.count
                    + GoalStore.shared.goals(for: child.id).filter { !$0.waitingToday.isEmpty }.count
                Button {
                    // Leo (the Demo's free-plan example) still opens: his
                    // page shows, with the trial-ended card over it.
                    if EvlinPlan.cardOnOpen( child.id) && !selected { proChild = child }
                    withAnimation(.snappy(duration: 0.3)) { session.activeChildId = child.id }
                } label: {
                    Text(String(child.name.prefix(2)).uppercased())
                        .font(Typography.font(11, weight: .heavy))
                        .foregroundStyle(child.color)
                        .frame(width: 32, height: 32)
                        .background(child.color.opacity(colorScheme == .dark ? 0.26 : 0.14), in: Circle())
                        .overlay(Circle().strokeBorder(EColor.surface, lineWidth: 2))
                        .overlay(Circle().strokeBorder(selected ? child.color : .clear, lineWidth: 2).padding(-2))
                        .scaleEffect(selected ? 1.14 : 1)
                        // In Dark the others fade less: at 0.45 they vanish.
                        .opacity(selected ? 1 : (colorScheme == .dark ? 0.75 : 0.45))
                        .overlay(alignment: .topTrailing) {
                            if waiting > 0 {
                                Text("\(waiting)")
                                    .font(Typography.font(9.5, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(HomeStyle.waiting, in: Capsule())
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
