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
    @Environment(\.dismiss) private var dismiss
    // iPad already renders this .sheet as a system form sheet (centered,
    // width-capped on its own) rather than full-bleed, so this mostly just
    // needs the same content-column cap and type bump as the rest of the
    // kid side for consistency, not a rescue from edge-to-edge stretching.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // "Parent Controls," not "Settings" — this sheet's only
                    // content is the one request below, and calling that
                    // "Settings" is exactly the mislabeling that got this
                    // pulled out of the kid's main tab bar in the first
                    // place (see TabletRootView).
                    Text("Parent Controls")
                        .font(Typography.display(kid.of(30, 34), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .padding(.top, 4)

                    parentControlsCard
                        .padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .kidContentColumn(kid.contentMaxWidth)
            }
            .background(KidTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(KidTheme.inkSoft)
                    }
                    .accessibilityLabel("Close")
                }
            }
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
                        .font(.system(size: kid.of(20, 24), weight: .semibold))
                        .foregroundStyle(KidTheme.greenDeep)
                }
                .frame(width: kid.of(44, 54), height: kid.of(44, 54))

                VStack(alignment: .leading, spacing: 4) {
                    Text("PARENT")
                        .font(Typography.font(kid.of(11, 12.5), weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(KidTheme.greenDeep)
                    Text("Parent controls")
                        .font(Typography.font(kid.of(16, 19), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text("Needs parent approval")
                        .font(Typography.font(kid.of(13, 15), weight: .medium))
                        .foregroundStyle(KidTheme.inkSoft)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(KidTheme.inkSoft)
            }
            .padding(kid.of(18, 22))
            .background(KidTheme.cream)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Parent controls, needs parent approval")
    }
}
