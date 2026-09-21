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
        // A read/sync failure — used to only ever reach a console `print`,
        // so a parent could be looking at stale or placeholder data with
        // zero indication anything was wrong. A banner, not an alert: a
        // background poll retries on every foreground and every 15s while
        // a screen is open, so a modal for each failed attempt would be
        // its own kind of broken UX. Clears itself the moment any sync
        // succeeds (see SyncState.syncError's own doc comment).
        .overlay(alignment: .top) { syncErrorBanner }
    }

    @ViewBuilder
    private var syncErrorBanner: some View {
        if let message = SyncState.shared.syncError {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                Text(message).font(.footnote).lineLimit(2)
                Spacer(minLength: 8)
                Button("Retry") { Task { await AppSync.shared.syncBackendData() } }
                    .font(.footnote.weight(.semibold))
                Button { SyncState.shared.syncError = nil } label: {
                    Image(systemName: "xmark")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(EColor.danger, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: SyncState.shared.syncError)
        }
    }
}
