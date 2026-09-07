import SwiftUI
import Sentry

@main
struct EvlinApp: App {
    init() {
        // A DSN is a write-only, non-secret identifier (per Sentry's own
        // docs) — safe to embed directly, unlike an API key. It's baked
        // into the shipped binary either way, so there's nothing gained
        // by routing it through a config file instead.
        SentrySDK.start { options in
            options.dsn = "https://f909b297a436a8439348a3f58012b9f4@o4512046626897920.ingest.us.sentry.io/4512046645116928"
            // Traces/profiling are for performance monitoring, not crash
            // reporting — this app has neither a backend nor slow
            // operations worth profiling yet, so both stay off rather
            // than sending data nobody will look at.
            options.tracesSampleRate = 0
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
