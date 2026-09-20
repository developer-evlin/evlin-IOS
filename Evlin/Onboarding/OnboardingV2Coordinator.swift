import SwiftUI
import UIKit
import FamilyControls

// Local-only v2 onboarding coordinator. Modeled on the real app's
// OnboardingCoordinator's v2 switch statement (Views/Onboarding/OnboardingCoordinator.swift),
// but stripped of everything that doesn't apply to this prototype: no
// AuthService / APIClient / FamilyStore, no v1/legacy branches, no DEBUG
// ladybug menu, no single-device interleave (this app picks ONE role per
// launch via ModePickerView, so there's no cross-device pairing to simulate —
// every "wait for the other device" screen just times out into success).

enum OnboardingV2Step: Equatable {
    // Parent chain
    case parentSignIn
    case parentProfile
    case parentBetaAgreement
    case parentPairScan
    case parentConnected
    case parentNotificationsAsk
    case parentWaitingForKid
    case parentDone

    // Kid chain
    case childProfile
    case childShowCode
    case childConnected
    case childScreenTime
    case childNotifications
    case childLockableHub
    case childFamilySharingAsk
    case childSafetyLock
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

    init(role: OnboardingV2Role, onExitToModePicker: (() -> Void)? = nil, onComplete: @escaping () -> Void) {
        self.role = role
        self.onExitToModePicker = onExitToModePicker
        self.onComplete = onComplete
        _step = State(initialValue: role == .parent ? .parentSignIn : .childProfile)
    }

    // MARK: Threaded state (parent chain)

    @State private var parentName = ""
    @State private var parentAvatar: UIImage?
    /// Fixed mock kid name — there's no second device to pair with, so the
    /// parent chain's "kid" is always this fake identity.
    @State private var kidName = "your child"
    @State private var pairedSucceeded = false

    // MARK: Threaded state (kid chain)

    @State private var childName = ""
    @State private var childAgeRange: String?
    @State private var childGender: String?
    @State private var childAvatar: UIImage?
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

    var body: some View {
        Group {
            switch step {

            // MARK: - Parent chain

            case .parentSignIn:
                ParentSignInStep(parentName: $parentName, onSignedIn: { hasKids in 
                    if hasKids {
                        step = .parentDone
                    } else {
                        step = .parentProfile
                    }
                }, onBack: onExitToModePicker)

            case .parentProfile:
                ParentProfileStep(
                    name: $parentName,
                    pickedAvatar: $parentAvatar,
                    onSaved: { step = .parentBetaAgreement },
                    onBack: { step = .parentSignIn }
                )

            case .parentBetaAgreement:
                ParentBetaAgreementStep(
                    onContinue: { step = .parentPairScan },
                    onBack: { step = .parentProfile }
                )

            case .parentPairScan:
                ParentShowCodeStep(
                    onContinue: { step = .parentConnected },
                    onBack: { step = .parentBetaAgreement }
                )

            case .parentConnected:
                ParentConnectedStep(
                    kidName: kidName,
                    onContinue: { step = .parentNotificationsAsk },
                    onBack: { step = .parentPairScan }
                )

            case .parentNotificationsAsk:
                ParentNotificationsAskStep(
                    onContinue: { step = .parentWaitingForKid },
                    onBack: { step = .parentConnected }
                )

            case .parentWaitingForKid:
                // The "send your first reflection" payoff-test screen and the
                // "finish setup on kid's device" screen were both cut —
                // straight to done once the kid's device is ready.
                ParentWaitingForKidStep(
                    kidName: kidName,
                    onReady: { _ in step = .parentDone },
                    onBack: { step = .parentNotificationsAsk }
                )

            case .parentDone:
                ParentOnboardingDoneStep(onEnter: onComplete)

            // MARK: - Kid chain

            case .childProfile:
                ChildProfileStep(
                    name: $childName,
                    ageRange: $childAgeRange,
                    gender: $childGender,
                    pickedAvatar: $childAvatar,
                    onContinue: { step = .childShowCode },
                    onBack: onExitToModePicker
                )

            case .childShowCode:
                ChildEnterCodeStep(
                    childName: childName,
                    onConnected: { step = .childConnected },
                    onBack: { step = .childProfile }
                )

            case .childConnected:
                ChildConnectedStep(
                    onContinue: { step = .childScreenTime },
                    onBack: { step = .childShowCode }
                )

            case .childScreenTime:
                ChildScreenTimeStep(
                    onContinue: { step = .childNotifications },
                    onBack: { step = .childConnected }
                )

            case .childNotifications:
                ChildNotificationsStep(
                    onContinue: { step = .childLockableHub },
                    onBack: { step = .childScreenTime }
                )

            case .childLockableHub:
                ChildLockableHubStep(
                    onContinue: { step = .childFamilySharingAsk },
                    onBack: { step = .childNotifications }
                )

            case .childFamilySharingAsk:
                // A Family Sharing child account already can't change its own
                // Screen Time settings without the organizer's approval — the
                // in-app PIN step exists only to cover families that aren't
                // set up that way, so this branch skips it entirely.
                ChildFamilySharingAskStep(
                    onYes: { step = .childReady },
                    onNo: { step = .childSafetyLock },
                    onBack: { step = .childLockableHub }
                )

            case .childSafetyLock:
                // Reuses the parent-side passcode screen with kid theming —
                // the Screen Time passcode is set ON the kid's own phone.
                ParentSetPasscodeV2Step(
                    kidName: childName,
                    onContinue: { step = .childReady },
                    onBack: { step = .childFamilySharingAsk },
                    role: .child,
                    phase: "5 · Safety",
                    stepIndex: 10,
                    dotsCurrent: 7,
                    total: 9
                )

            case .childReady:
                ChildOnboardingReadyStep(onEnter: onComplete)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Mocked "backend" calls

    /// Mock POST /family/pair: any 6-digit code succeeds.
    @MainActor
    private func pairWithKidCode(_ code: String) async -> String? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        pairedSucceeded = true
        return nil
    }
}
