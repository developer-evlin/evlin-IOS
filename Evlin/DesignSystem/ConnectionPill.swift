import SwiftUI

/// What the connection means for the user's changes (ConnectionStatus),
/// floating at the top of each tab (`withConnectionPill`) without moving
/// the screen. Nothing while things work.
///
/// Offline is the one to act on, so it's said plainly and can't be missed.
/// It stays until the phone is back online. The server not answering is the
/// app's to retry, so that card only says changes are kept; being back and
/// caught up is a small pill, for a moment.
struct ConnectionPill: View {
    /// The kid's words instead of the parent's.
    var kid = false

    private var status: ConnectionStatus { .shared }

    private enum Look { case card(icon: String, title: String, detail: String), pill(icon: String, text: String) }

    private var look: Look? {
        switch status.phase {
        case .fine:
            return nil
        case .offline:
            return .card(icon: "wifi.slash", title: "Please check your internet connection", detail: "")
        case .unreachable:
            return .card(icon: "arrow.triangle.2.circlepath", title: "Can't reach Evlin",
                         detail: kid ? "Your progress is saved here and will send when it's back."
                                     : "Your changes are saved on this phone and will sync when it's back.")
        case .caughtUp:
            return .pill(icon: "checkmark", text: kid ? "Back online · all sent" : "Back online · all saved")
        }
    }

    var body: some View {
        ZStack {
            switch look {
            case let .card(icon, title, detail):
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "FFB547"))
                        .frame(width: 22)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Typography.font(15, weight: .bold))
                            .foregroundStyle(.white)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(Typography.font(13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 520)
                .background(EColor.inkFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            case let .pill(icon, text):
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(text)
                        .font(Typography.font(13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(EColor.surfaceContainerHigh, in: Capsule())
                .overlay(Capsule().strokeBorder(EColor.outlineVariant.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            case nil:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: status.phase)
        // Never in the way of a tap below it.
        .allowsHitTesting(false)
    }
}

extension View {
    /// The connection message floating at the top of this tab, over its
    /// content: the screen doesn't move when it comes and goes, and taps go
    /// through it. Inside the tab, not around the tab view: a tab view that
    /// changes size leaves its tabs' touch areas behind.
    func withConnectionPill(kid: Bool = false) -> some View {
        overlay(alignment: .top) {
            ConnectionPill(kid: kid)
        }
    }
}
