import SwiftUI
import Lottie

/// Looping Lottie illustration from Resources/Animations/<name>.json — used
/// in place of static icons at a few "reinforce this moment" spots (parent
/// PIN screens, notifications ask) rather than every icon in the app.
struct LottieIllustration: View {
    var name: String
    var size: CGFloat = 140

    var body: some View {
        LottieView(animation: .named(name))
            .playing(loopMode: .loop)
            .resizable()
            .frame(width: size, height: size)
    }
}

/// DataSecurity.json — parent PIN screens (onboarding Create/Confirm PIN,
/// the kid-device Parent Controls gate).
struct SecurityLottieView: View {
    var size: CGFloat = 140
    var body: some View { LottieIllustration(name: "DataSecurity", size: size) }
}

/// Alerts.json — the parent notifications-ask onboarding screen.
struct NotificationsLottieView: View {
    var size: CGFloat = 140
    var body: some View { LottieIllustration(name: "Alerts", size: size) }
}

/// ContractSign.lottie — the beta/user agreement onboarding screen. A
/// `.lottie` (dotLottie) file, not a raw `.json`, so it loads via
/// DotLottieFile instead of LottieIllustration's `.named(_:)`.
struct ContractSignLottieView: View {
    var size: CGFloat = 140

    var body: some View {
        LottieView {
            try await DotLottieFile.named("ContractSign")
        }
        .playing(loopMode: .loop)
        .resizable()
        .frame(width: size, height: size)
    }
}

/// ScreenTimeGrant.lottie — the kid-device Screen Time authorization step.
/// Also a `.lottie` (dotLottie) file, loaded the same way as
/// ContractSignLottieView above.
struct ScreenTimeGrantLottieView: View {
    var size: CGFloat = 140

    var body: some View {
        LottieView {
            try await DotLottieFile.named("ScreenTimeGrant")
        }
        .playing(loopMode: .loop)
        .resizable()
        .frame(width: size, height: size)
    }
}
