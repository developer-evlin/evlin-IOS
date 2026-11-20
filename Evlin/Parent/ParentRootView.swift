import SwiftUI

struct ParentRootView: View {
    var onSwitchMode: () -> Void
    var onSignOut: (() -> Void)? = nil

    @State private var tab = DemoMode.parentTab ?? 0
    @ObservedObject private var goals = GoalStore.shared
    @ObservedObject private var spotlight = FirstLockSpotlight.shared
    @ObservedObject private var habitTour = HabitTour.shared

    var body: some View {
        TabView(selection: $tab) {
            ScreenHome()
                .withConnectionPill()
                // The tab bar floats over any overlay: hidden while the
                // first lock's spotlight dims the app.
                .toolbar(spotlight.lock == nil && !habitTour.showing ? .automatic : .hidden, for: .tabBar)
                .tabItem { Image(systemName: "house.fill").accessibilityLabel("Home") }
                .tag(0)
            ScreenChat()
                .withConnectionPill()
                .tabItem { Image(systemName: "bubble.left.fill").accessibilityLabel("Chat") }
                .tag(2)
            // The child's profile: screen time, blocked apps, downtime and
            // adding tasks as big buttons. Settings is behind its gear.
            ScreenChildProfile(onSwitchMode: onSwitchMode, onSignOut: onSignOut)
                .withConnectionPill()
                // A clock: the tab is the child's screen time (2026-11-12, the
                // user's call; an hourglass, and a person in a circle, before).
                .tabItem { Image(systemName: "clock.fill").accessibilityLabel("Screen time") }
                .tag(3)
        }
        .tint(EColor.primary)
        // The bar in the page's cream, not the system's near-white.
        .toolbarBackground(EColor.surface, for: .tabBar)
        // The first lock's spotlight, over the tabs too.
        .overlay { FirstLockSpotlightView() }
        // The first habit's tour, over the tabs too.
        .overlay { HabitTourView() }
        #if EVLIN_DEMO
        .overlay { if DemoMode.parentOpen == "artgallery" { HabitArtGallery() } }
        #endif
        .background(UnlockTrustWatcher())
        .background(MilestoneCelebrationWatcher())
        // A goal reached: the parent's choice of what's next opens New habit.
        .sheet(item: $goals.nextHabit) { next in
            if let child = FamilyStore.children.first(where: { $0.id == next.childId }) {
                NewGoalSheet(child: child, again: next.again)
            }
        }
        // Any background save that failed (approve, lock, rule edit, …).
        .alert("Couldn't save", isPresented: Binding(
            get: { SyncState.shared.writeError != nil },
            set: { if !$0 { SyncState.shared.writeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(SyncState.shared.writeError ?? "")
        }
        // Offline, or Evlin not answering: each tab shows a quiet grey pill
        // at its top (withConnectionPill, ConnectionStatus).
    }
}
