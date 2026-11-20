import CryptoKit
import Foundation
import LocalAuthentication

/// The screen time access code (2026-11-19): what a parent types on their
/// child's device to get into its settings.
///
/// Six random digits made and checked only on the server
/// (`app.access_codes`, routers/access_codes.py), never kept on a device
/// (2026-11-19, the user's call: it lived on the devices as a secret before).
/// One parent's code opens any of their children's devices, for a minute and
/// once: typed right, it's used up. The parent's phone shows it after Face
/// ID, Touch ID or the phone's passcode; the child's device asks every time
/// its settings are opened, so it needs to be online.
enum AccessCode {
    static let digits = 6

    /// The code on show and when it runs out, by this phone's clock.
    struct Current: Equatable {
        var code: String
        var expires: Date
        var lifetime: TimeInterval

        func fractionLeft(at date: Date) -> Double {
            max(0, min(1, expires.timeIntervalSince(date) / lifetime))
        }
    }

    /// The parent's phone: the code now (the same one while it's good).
    static func fetch() async throws -> Current {
        if DemoMode.isBuild { return demoCurrent(at: Date()) }
        let answer = try await APIClient.shared.accessCode()
        return Current(code: answer.code, expires: Date().addingTimeInterval(answer.secondsLeft),
                       lifetime: max(1, answer.lifetime))
    }

    /// The child's device: whether `typed` opens its settings. Throws when
    /// the server can't be reached.
    static func check(_ typed: String) async throws -> Bool {
        guard typed.count == digits, typed.allSatisfy(\.isNumber) else { return false }
        if DemoMode.isBuild {
            // No server in the Demo: both simulators work the minute's code
            // out the same way; the one before still counts while walking over.
            let now = Date()
            return [now, now.addingTimeInterval(-demoStep)].contains { demoCode(at: $0) == typed }
        }
        return try await APIClient.shared.checkAccessCode(typed)
    }

    // MARK: - Demo

    private static let demoStep: TimeInterval = 60

    private static func demoCode(at date: Date) -> String {
        let minute = Int(date.timeIntervalSince1970 / demoStep)
        let hash = SHA256.hash(data: Data("evlin-demo-access-\(minute)".utf8))
        let value = hash.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    private static func demoCurrent(at date: Date) -> Current {
        let start = (date.timeIntervalSince1970 / demoStep).rounded(.down) * demoStep
        return Current(code: demoCode(at: date), expires: Date(timeIntervalSince1970: start + demoStep), lifetime: demoStep)
    }
}

/// It's the parent holding the phone: Face ID, Touch ID or the phone's own
/// passcode, as iOS asks for it.
enum ParentIdentity {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A phone with no passcode at all: anyone holding it is in
            // already, so there's nothing to check against.
            return error?.code == LAError.passcodeNotSet.rawValue
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
