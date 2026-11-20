import Foundation

/// Setting up Family Sharing is shared between the two devices
/// (2026-11-11, the user's call). The kid's device plays how to create the
/// child's Apple Account on the parent's iPhone, and the parent's phone
/// offers Open Settings and "I've created the account" meanwhile. Tapped on
/// either device, the kid's device says to sign it in ("Sign this iPad in")
/// and the parent's phone turns its leaf into the steps for signing the
/// kid's device in with that account.
///
/// The server carries the stage (`devices.setup_stage`, "account_created"
/// or none), set by the kid's device; the parent's phone reads it with the
/// children it already checks. In the Demo, the linked simulators share it
/// through the bridge file instead.
@MainActor
enum FamilySharingHandOff {
    nonisolated enum Stage: String {
        /// The kid's device shows how to make the child's account: the
        /// parent's phone offers Open Settings and "I've created the account".
        case creatingAccount = "creating_account"
        /// The account is made: the kid's device is waiting to be signed in.
        case accountCreated = "account_created"
        /// "Mia's account is signed in", tapped on the kid's device: the
        /// parent's phone turns back to the leaf and says so (2026-11-12).
        case signedIn = "signed_in"
    }

    /// The kid's device is on the account steps.
    static func kidCreatingAccount() { kidSets(Stage.creatingAccount.rawValue) }

    /// "I've created the account", tapped on the kid's device.
    static func kidAccountCreated() { kidSets(Stage.accountCreated.rawValue) }

    /// "Mia's account is signed in", tapped on the kid's device.
    static func kidSignedIn() { kidSets(Stage.signedIn.rawValue) }

    /// Left the step.
    static func kidLeaves() { kidSets("") }

    /// "I've created the account", tapped on the parent's phone instead: the
    /// kid's device moves on as if it had been tapped there (2026-11-11).
    static func parentAccountCreated(childId: String?) {
        if DemoPairBridge.isOn {
            DemoPairBridge.update {
                if $0.setupStage == Stage.creatingAccount.rawValue { $0.setupStage = Stage.accountCreated.rawValue }
            }
        } else if ServerSupport.familySharingHandOff, !DemoMode.isBuild, let childId {
            Outbox.send(APIClient.Write.childAccountCreated(childId), label: "Family Sharing setup")
        }
    }

    /// The stage as the server (or the Demo's bridge) has it, read by the
    /// kid's device to hear the parent's tap.
    static func kidReadsStage() async -> Stage? {
        if DemoPairBridge.isOn {
            return DemoPairBridge.read()?.setupStage.flatMap(Stage.init)
        }
        guard ServerSupport.familySharingHandOff, !DemoMode.isBuild,
              let me = try? await APIClient.shared.fetchMyChild() else { return nil }
        return me.setupStage.flatMap(Stage.init)
    }

    private static func kidSets(_ stage: String) {
        if DemoPairBridge.isOn {
            DemoPairBridge.update { $0.setupStage = stage.isEmpty ? nil : stage }
        } else if ServerSupport.familySharingHandOff, !DemoMode.isBuild {
            Outbox.send(APIClient.Write.mySetupStage(stage), label: "Family Sharing setup")
        }
    }
}
