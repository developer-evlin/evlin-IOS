import SwiftUI

enum BillingCycle { case monthly, yearly }

// Shared so the plan shows the same way wherever it's surfaced — the
// Settings billing page (where a parent actually upgrades/cancels) and the
// compact read-only row on a kid's profile (ScreenProfile.planRow) both
// observe the same instance instead of drifting out of sync.
final class BillingState: ObservableObject {
    static let shared = BillingState()

    @Published var isPlus = false
    @Published var billingCycle: BillingCycle = .yearly

    private init() {}
}
