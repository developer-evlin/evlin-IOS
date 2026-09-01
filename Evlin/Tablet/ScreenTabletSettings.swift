import SwiftUI

// Its own tab now (used to be a card at the top of ScreenTabletHome) — the
// kid-side entry point into parent controls. Requests passwordless parent
// approval; see ParentApprovalWaitingView below and ScreenProfile.approvalBanner
// on the parent side.
struct ScreenTabletSettings: View {
    var onSwitchMode: () -> Void

    // Deliberately NOT TabletData.child (Liam) — the parent-approval demo
    // is scoped to whichever child is last in FamilyStore.children (Jake
    // today) so it never fires against the "real" kid this prototype's
    // other screens are themed around. parentApprovalStatus lives on the
    // Child record itself, so a status change made from inside the parent's
    // profile (a mode switch away, on this single-device prototype) is
    // still reflected here the next time this view checks it.
    @ObservedObject private var childProfile = FamilyStore.children.last ?? FamilyStore.child(TabletData.child.id)
    @State private var showApprovalWait = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(Typography.display(30, weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .padding(.top, 4)

                    parentControlsCard
                        .padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
            .background(KidTheme.background)
        }
        .sheet(isPresented: $showApprovalWait) {
            ParentApprovalWaitingView(
                child: childProfile,
                onApproved: {
                    showApprovalWait = false
                    childProfile.parentApprovalStatus = .none
                    onSwitchMode()
                },
                onCancel: {
                    childProfile.parentApprovalStatus = .none
                    showApprovalWait = false
                }
            )
        }
    }

    private var parentControlsCard: some View {
        Button {
            if childProfile.parentApprovalStatus == .approved {
                // One-time use, like the PIN it replaced — each entry
                // attempt needs its own fresh approval.
                childProfile.parentApprovalStatus = .none
                onSwitchMode()
            } else {
                childProfile.parentApprovalStatus = .pending
                showApprovalWait = true
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(KidTheme.greenTint)
                    Image(systemName: "lock.rectangle.stack.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(KidTheme.greenDeep)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PARENT")
                        .font(Typography.font(11, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(KidTheme.greenDeep)
                    Text("Parent controls")
                        .font(Typography.font(16, weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text("Needs parent approval")
                        .font(Typography.font(13, weight: .medium))
                        .foregroundStyle(KidTheme.inkSoft)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(KidTheme.inkSoft)
            }
            .padding(18)
            .background(KidTheme.cream)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Parent controls, needs parent approval")
    }
}
