import SwiftUI
import UIKit
import FamilyControls

// v2 onboarding coordinator. Modeled on the real app's OnboardingCoordinator's
// v2 switch statement (Views/Onboarding/OnboardingCoordinator.swift), but
// stripped of the v1/legacy branches, the DEBUG ladybug menu, and the
// single-device interleave (this app picks ONE role per launch via
// ModePickerView, so parent and kid always run this chain on separate
// devices — real cross-device pairing, via APIClient's pairing endpoints,
// not something simulated locally).

enum OnboardingV2Step: Equatable, CaseIterable {
    // Parent chain
    case parentSignIn
    case parentProfile
    case parentBetaAgreement
    case parentPairScan
    case parentConnected
    case parentNotificationsAsk
    case parentWaitingForKid
    case parentDone

    // Kid chain, in order: the kid's profile and pairing, then how Evlin is
    // locked in (Family Sharing, or a PIN), then the permissions and apps.
    case childProfile
    case childShowCode
    case childConnected
    case childFamilySharingAsk
    case childLockChoice
    case childFamilySharingSetup
    case childSafetyLock
    case childScreenTime
    case childNotifications
    case childLockableHub
    case childReady
}

struct OnboardingV2Coordinator: View {
    let role: OnboardingV2Role
    let onComplete: () -> Void
    // Back button on the very first step (sign in / kid profile), for
    // backing out to the mode picker. nil hides it — the caller only passes
    // this the first time a given role enters onboarding in this session;
    // once they've been through here once, RootView stops offering the
    // escape hatch back to the picker on subsequent entries.
    var onExitToModePicker: (() -> Void)? = nil

    @State private var step: OnboardingV2Step
    /// Which way the step change in progress goes. Read by the transition
    /// while it plays (see `OnboardingStepSlide`), not baked in when a
    /// screen was last drawn. Steps are ordered by their enum position.
    @State private var direction = OnboardingStepDirection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(role: OnboardingV2Role, onExitToModePicker: (() -> Void)? = nil, onComplete: @escaping () -> Void) {
        self.role = role
        self.onExitToModePicker = onExitToModePicker
        self.onComplete = onComplete
        // A kid's phone that already holds a device token (a reinstall, or
        // closed partway through setup) is still paired: only the parent
        // unpairing ends that. Skip to the permissions, which a reinstall
        // does lose. The token is checked in `confirmStillPaired`.
        let paired = role == .child && SessionManager.shared.childDeviceToken != nil
        _resumedPairing = State(initialValue: paired)
        let parentStart = DemoMode.parentOnboardingStep
            ?? (DemoMode.previewsOnboarding ? .parentProfile : .parentSignIn)
        _step = State(initialValue: role == .parent ? parentStart : (paired ? .childScreenTime : Self.kidFirstStep))
        if role == .child, let start = DemoMode.kidOnboardingStep { _step = State(initialValue: start) }
    }

    /// The kid chain started past pairing, with the device token it had.
    @State private var resumedPairing: Bool
    /// Where Screen Time's Back goes: the page the child's device came
    /// from (2026-11-13, the user's catch: after the Family Sharing account
    /// steps it went to "Do you use Family Sharing?").
    @State private var screenTimeBack: OnboardingV2Step = .childFamilySharingAsk

    /// Asks the server whether the saved device token still works. Unpaired
    /// (401): forget it and pair again. Offline: carry on, the next sync asks.
    private func confirmStillPaired() async {
        guard resumedPairing else { return }
        do {
            let me = try await APIClient.shared.fetchMyChild()
            SessionManager.shared.activeChildId = me.id
            if childName.isEmpty { childName = me.name }
        } catch let failure as APIFailure where failure.status == 401 {
            SessionManager.shared.childDeviceToken = nil
            SessionManager.shared.activeChildId = nil
            resumedPairing = false
            go(Self.kidFirstStep)
        } catch {}
    }

    /// The kid's first setup step: the code, or the name first until the
    /// server takes the name after pairing (ServerSupport.nameAfterPairing).
    private static var kidFirstStep: OnboardingV2Step {
        ServerSupport.nameAfterPairing ? .childShowCode : .childProfile
    }

    // MARK: Threaded state (parent chain)

    @State private var parentName = ""
    /// Generic placeholder until the real pairing poll (ParentScanCodeStep)
    /// reports the name the kid actually typed on their own device — see
    /// the EvlinKidPaired notification handler below.
    @State private var kidName = "your child"

    // MARK: Threaded state (kid chain)

    @State private var childName = ""
    @State private var childAgeRange: String?
    @State private var childGender: String?
    /// The code this device generated in ChildShowCodeStep.
    @State private var myPairingCode = ""
    /// Lifted out of ChildLockableHubStep so a kid backing up to an earlier
    /// step and returning to it doesn't lose what they already picked —
    /// SwiftUI recreates that step's own @State from scratch each time the
    /// switch below re-selects its case, since other cases render in
    /// between.
    // Removed lockableAppSelection from here because instantiating FamilyActivitySelection()
    // at the root level of the coordinator triggers an XPC call to the FamilyControls daemon
    // which causes a synchronous block and a Swift Concurrency panic (unsafeForcedSync)
    // when the user simply switches to the Kid mode.

    private static func order(_ step: OnboardingV2Step) -> Int {
        OnboardingV2Step.allCases.firstIndex(of: step) ?? 0
    }

    private func go(_ next: OnboardingV2Step) {
        guard next != step else { return }
        let isForward = Self.order(next) >= Self.order(step)
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)
        // SwiftUI animates a leaving screen with the transition it had when
        // last drawn. Swapping transitions by direction (and redrawing first
        // to get the new one in) didn't land in time: Back played the
        // forward animation, the old screen stayed on top and the new one
        // popped in at the end. One transition that asks which way while it
        // runs can't be out of date.
        direction.forward = isForward
        withAnimation(animation) { step = next }
    }

    // Matches the system navigation push, per Apple's HIG on motion
    // (follow people's expectations; keep it brief). Forward: the new screen
    // slides over from the trailing edge while the old one shifts a third of
    // the way left and dims. Back is the exact reverse. Reduce Motion gets a
    // cross-fade instead.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingStepSlide(progress: 1, isInsertion: true, direction: direction),
                identity: OnboardingStepSlide(progress: 0, isInsertion: true, direction: direction)),
            removal: .modifier(
                active: OnboardingStepSlide(progress: 1, isInsertion: false, direction: direction),
                identity: OnboardingStepSlide(progress: 0, isInsertion: false, direction: direction))
        )
    }

    var body: some View {
        ZStack {
            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Opaque edge to edge, so the screen underneath doesn't show
                // through the safe areas while the two overlap mid-push.
                .background(EPaperBackground())
                // Later steps sit above earlier ones, so going forward the
                // new screen covers the old, and going back the old one
                // slides off the top of the new.
                .zIndex(Double(Self.order(step)))
                .id(step)
                .transition(stepTransition)
        }
        // One haptic, at the moments that mean something finished — the
        // pairing and the end of setup — not on every step (HIG: avoid
        // overusing haptics; use system patterns for what they mean).
        .sensoryFeedback(.success, trigger: step) { _, new in
            [.parentConnected, .childConnected, .parentDone, .childReady].contains(new)
        }
        // Posted by the parent's pairing poll with the name the child typed
        // on their own device, so the "connected" screens use it.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("EvlinKidPaired"))) { note in
            if let name = note.object as? String, !name.isEmpty { kidName = name }
        }
        .task { await confirmStillPaired() }
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {

        // MARK: - Parent chain

        case .parentSignIn:
            // Already paired: through the waiting step (instant once the
            // kid's device has finished its setup), so closing the app can't
            // skip it. Otherwise on with setup, asking for the parent's name
            // only if the sign-in didn't bring one.
            ParentSignInStep(parentName: $parentName, onSignedIn: { hasKids, hasName in
                if hasKids {
                    go(.parentWaitingForKid)
                } else {
                    go(hasName ? .parentBetaAgreement : .parentProfile)
                }
            }, onBack: onExitToModePicker)

        case .parentProfile:
            ParentProfileStep(
                name: $parentName,
                onSaved: { go(.parentBetaAgreement) },
                onBack: { go(.parentSignIn) }
            )

        // The parent's order (2026-11-10, the user's call): sign up, the
        // agreement, notifications, then pairing, so pairing is the last
        // thing before the parent goes over to the child's device.
        case .parentBetaAgreement:
            ParentBetaAgreementStep(
                onContinue: { go(.parentNotificationsAsk) },
                onBack: { go(.parentProfile) }
            )

        case .parentNotificationsAsk:
            ParentNotificationsAskStep(
                onContinue: {
                    // The Demo walkthrough skips the scan, unless two
                    // simulators are linked to pair for real (`DemoPairBridge`).
                    if DemoMode.previewsOnboarding && !DemoPairBridge.isOn { kidName = "Mia"; go(.parentWaitingForKid) } else { go(.parentPairScan) }
                },
                onBack: { go(.parentBetaAgreement) }
            )

        case .parentPairScan:
            ParentScanCodeStep(
                onPaired: { name in kidName = name; go(.parentWaitingForKid) },
                onBack: { go(.parentNotificationsAsk) }
            )

        case .parentConnected:
            ParentConnectedStep(
                kidName: kidName,
                onContinue: { go(.parentWaitingForKid) },
                onBack: { go(.parentPairScan) }
            )

        case .parentWaitingForKid:
            // The payoff-test screen and the "finish setup on kid's
            // device" screen were both cut —
            // straight to done once the kid's device is ready.
            ParentWaitingForKidStep(
                kidName: kidName,
                onReady: { go(.parentDone) }
            )

        case .parentDone:
            ParentOnboardingDoneStep(onEnter: onComplete)

        // MARK: - Kid chain

        // The kid's setup pairs first (the QR), then asks who's using the
        // iPad (2026-11-09, the user's call): the name goes to the server
        // from here, the code having been asked for without one.
        case .childShowCode:
            // Until the server takes the name from the kid's device after
            // pairing (ServerSupport.nameAfterPairing), the name is asked
            // first and goes with the pairing request instead.
            ChildShowCodeStep(
                childName: ServerSupport.nameAfterPairing ? ""
                    : childName.trimmingCharacters(in: .whitespacesAndNewlines),
                onConnected: { go(.childConnected) },
                onBack: ServerSupport.nameAfterPairing ? onExitToModePicker : { go(.childProfile) }
            )

        // Paired is a one-way door (2026-11-12, the user's call): no Back on
        // Connected or the name step after it. Back went to the QR, which
        // started a new pairing the parent's phone, already moved on, never
        // claimed, so both got stuck.
        case .childConnected:
            ChildConnectedStep(
                onContinue: { go(ServerSupport.nameAfterPairing ? .childProfile : .childFamilySharingAsk) }
            )

        case .childProfile:
            ChildProfileStep(
                name: $childName,
                ageRange: $childAgeRange,
                gender: $childGender,
                onContinue: {
                    let name = childName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ServerSupport.nameAfterPairing else {
                        // Asked before pairing: the code step sends it.
                        go(.childShowCode)
                        return
                    }
                    if !DemoMode.isBuild, !name.isEmpty {
                        Outbox.send(APIClient.Write.nameMyChild(name), label: "\(name)'s name")
                    }
                    DemoPairBridge.update { $0.kidName = name }
                    go(.childFamilySharingAsk)
                },
                onBack: ServerSupport.nameAfterPairing ? nil : onExitToModePicker
            )

        case .childScreenTime:
            ChildScreenTimeStep(
                onContinue: { go(.childNotifications) },
                // Resumed: there's no pairing to go back to.
                onBack: resumedPairing ? onExitToModePicker : { go(screenTimeBack) }
            )

        case .childNotifications:
            ChildNotificationsStep(
                onContinue: { go(.childLockableHub) },
                onBack: { go(.childScreenTime) }
            )

        case .childLockableHub:
            ChildLockableHubStep(
                onContinue: {
                    DemoPairBridge.update { $0.kidDone = true }
                    go(.childReady)
                },
                onBack: { go(.childNotifications) }
            )

        case .childFamilySharingAsk:
            // Right after pairing. A Family Sharing child account already
            // can't change its own Screen Time settings without the
            // organizer's approval, so that branch goes straight on; the
            // others are offered Family Sharing, or a Screen Time PIN.
            ChildFamilySharingAskStep(
                onYes: { screenTimeBack = .childFamilySharingAsk; go(.childScreenTime) },
                onNo: { go(.childLockChoice) },
                // Paired is a one-way door: with the name asked before
                // pairing, the step before this one is Connected.
                onBack: ServerSupport.nameAfterPairing ? { go(.childProfile) } : nil
            )

        case .childLockChoice:
            ChildLockChoiceStep(
                kidName: childName,
                onFamilySharing: { go(.childFamilySharingSetup) },
                onPIN: { go(.childSafetyLock) },
                onBack: { go(.childFamilySharingAsk) }
            )

        case .childFamilySharingSetup:
            ChildFamilySharingSetupStep(
                kidName: childName,
                onDone: { screenTimeBack = .childFamilySharingSetup; go(.childScreenTime) },
                onBack: { go(.childLockChoice) }
            )

        case .childSafetyLock:
            // Reuses the parent-side passcode screen with kid theming —
            // the Screen Time passcode is set ON the kid's own phone.
            ParentSetPasscodeV2Step(
                kidName: childName,
                onContinue: { screenTimeBack = .childSafetyLock; go(.childScreenTime) },
                onBack: { go(.childLockChoice) },
                role: .child,
                phase: "3 · Safety",
                stepIndex: 5,
                dotsCurrent: 7,
                total: 9
            )

        case .childReady:
            ChildOnboardingReadyStep(onEnter: onComplete)
        }
    }
}

/// Which way the onboarding is moving. A reference, so a transition already
/// under way reads the current value.
final class OnboardingStepDirection {
    var forward = true
}

// A step change, like UINavigationController's push and pop. The screen on
// top slides in from (or out to) the trailing edge; the one underneath
// shifts a third of its width toward the leading edge and dims. Forward, the
// new screen is on top; back, the old one is. Taps are off for the whole
// transition so a second tap on a leaving screen can't fire its button again.
private struct OnboardingStepSlide: ViewModifier, Animatable {
    /// 0 when settled, 1 fully off.
    var progress: Double
    let isInsertion: Bool
    let direction: OnboardingStepDirection

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Forward, the arriving screen is the top one; back, the leaving one.
        let onTop = isInsertion == direction.forward
        let shift = onTop ? progress : -0.3 * progress
        let dim = onTop ? 0 : 0.12 * progress
        content
            .visualEffect { view, proxy in
                view.offset(x: proxy.size.width * shift)
            }
            .overlay(Color.black.opacity(dim).ignoresSafeArea().allowsHitTesting(false))
            .allowsHitTesting(progress == 0)
    }
}
