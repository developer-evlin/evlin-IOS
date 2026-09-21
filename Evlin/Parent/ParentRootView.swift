import SwiftUI

struct ParentRootView: View {
    @Environment(SessionManager.self) private var session

    var onSwitchMode: () -> Void
    var onSignOut: (() -> Void)? = nil
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ScreenHome()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            ScreenCalendar(isActive: tab == 1)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(1)
            ScreenChat()
                .tabItem { Label("Chat", systemImage: "bubble.left.fill") }
                .tag(2)
            ScreenLibrary()
                .tabItem { Label("Library", systemImage: "book.pages") }
                .tag(3)
            ScreenSettings(onSwitchMode: onSwitchMode, onSignOut: onSignOut)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(EColor.primary)
        // Any background save that failed (approve, lock, rule edit, …).
        .alert("Couldn't save", isPresented: Binding(
            get: { SyncState.shared.writeError != nil },
            set: { if !$0 { SyncState.shared.writeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(SyncState.shared.writeError ?? "")
        }
    }
}
