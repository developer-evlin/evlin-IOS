import SwiftUI

// Shown when a kid taps "Parent controls" (ScreenTabletHome.parentControlsCard)
// and there's no standing approval yet — replaces the old SettingsPINGateView
// keypad. There's nothing to type here: the kid's device just sits blocked
// until a parent, from inside this same kid's profile on the parent side
// (ScreenProfile.approvalBanner), taps Approve. `onApproved` fires the
// instant that happens, via the onChange below, for the (currently
// hypothetical, single-device) case both screens are live at once.
struct ParentApprovalWaitingView: View {
    @ObservedObject var child: Child
    var onApproved: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            SecurityLottieView(size: 120)

            VStack(spacing: 8) {
                Text("Waiting for parent approval")
                    .font(Typography.display(20, weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                Text("Ask your parent to open your profile in Evlin and approve — nothing happens on this device until they do.")
                    .font(Typography.font(14, weight: .medium))
                    .foregroundStyle(KidTheme.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button("Cancel request", action: onCancel)
                .font(Typography.font(14, weight: .bold))
                .foregroundStyle(KidTheme.inkSoft)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KidTheme.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .onChange(of: child.parentApprovalStatus) { _, status in
            if status == .approved { onApproved() }
        }
    }
}
