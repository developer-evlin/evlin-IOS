import Foundation
import SwiftUI

@Observable
class SessionManager {
    static let shared = SessionManager()
    
    var parentAccessToken: String?
    var childDeviceToken: String?
    
    // The UUID of the child whose data is currently being viewed/managed.
    // For MVP, if a parent has multiple children, they would switch this.
    // On the kid's device, this is just their own ID.
    var activeChildId: String?
    
    var activeToken: String? {
        return parentAccessToken ?? childDeviceToken
    }
    
    func clear() {
        parentAccessToken = nil
        childDeviceToken = nil
        activeChildId = nil
    }
}
