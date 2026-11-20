import SwiftUI
import Sentry

@main
struct EvlinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Started only to host the unit tests (EvlinTests). The app then shows
    /// nothing and starts nothing (no sync, no live updates, no Sentry), so
    /// the tests aren't racing whatever account is on that simulator.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if Self.isHostingTests { return }
        ChatType.registerFont()
        // A DSN is a write-only, non-secret identifier (per Sentry's own
        // docs) — safe to embed directly, unlike an API key. It's baked
        // into the shipped binary either way, so there's nothing gained
        // by routing it through a config file instead.
        // The Demo build reports nothing: its sample family isn't a real one.
        if !DemoMode.isBuild { SentrySDK.start { options in
            options.dsn = "https://f909b297a436a8439348a3f58012b9f4@o4512046626897920.ingest.us.sentry.io/4512046645116928"
            // Traces/profiling are for performance monitoring, not crash
            // reporting — this app has neither a backend nor slow
            // operations worth profiling yet, so both stay off rather
            // than sending data nobody will look at.
            options.tracesSampleRate = 0
        } }
        MainActor.assumeIsolated {
            DemoMode.seedIfOn()
            ConnectionStatus.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isHostingTests { Color.clear } else { RootView() }
        }
        // iOS wakes the app now and then to sync (see BackgroundSync).
        .backgroundTask(.appRefresh(BackgroundSync.refreshID)) {
            await BackgroundSync.refresh()
        }
    }
}

/// Which way the screen may turn. iPad: any way, always. iPhone: portrait,
/// unless a screen sets `allowsLandscape` (none does since the video
/// player was removed).
@MainActor
enum OrientationLock {
    static var allowsLandscape = false {
        didSet {
            guard UIDevice.current.userInterfaceIdiom == .phone, allowsLandscape != oldValue else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                if !allowsLandscape {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS finished (or needs us to finish) photo uploads it carried while
    /// the app was closed: the session is made again to hear the results.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploads.identifier else { return completionHandler() }
        BackgroundUploads.shared.finishEvents = completionHandler
        _ = BackgroundUploads.shared.session
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return MainActor.assumeIsolated { OrientationLock.allowsLandscape } ? .allButUpsideDown : .portrait
    }
}
