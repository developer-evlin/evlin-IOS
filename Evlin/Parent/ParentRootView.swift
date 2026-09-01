import SwiftUI

struct ParentRootView: View {
    var onSwitchMode: () -> Void
    @Binding var taskTutorialDone: Bool
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ScreenHome(onSwitchMode: onSwitchMode, taskTutorialDone: $taskTutorialDone)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            ScreenCalendar()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(1)
            ScreenChat()
                .tabItem { Label("Chat", systemImage: "bubble.left.fill") }
                .tag(2)
            ScreenLibrary()
                .tabItem { Label("Library", systemImage: "book.pages") }
                .tag(3)
            ScreenSettings()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(EColor.primary)
    }
}
