import Foundation

/// A lightweight API client to connect the SwiftUI app to the local FastAPI backend.
class APIClient {
    static let shared = APIClient()
    
    // Using localhost for simulator testing. 
    // If testing on a physical device, this would change to the Mac's local IP (e.g., http://192.168.x.x:8000)
    let baseURL = "http://127.0.0.1:8000"
    
    // Store tokens in memory for the prototype MVP (normally this would be Keychain)
    var parentAccessToken: String?
    var childDeviceToken: String?
    
    // MARK: - Authentication & Pairing
    
    func generatePairingCode(childId: String) async throws -> (code: String, expiresAt: String) {
        // Simulating the request for now if no token is present, 
        // otherwise this will hit POST /auth/generate-pairing-code
        
        let url = URL(string: "\(baseURL)/auth/generate-pairing-code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // MVP Mock behavior if the backend isn't actively running/authenticated
        // In reality we would attach the parentAccessToken as a Bearer token
        if let token = parentAccessToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = ["child_id": childId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = json?["pairing_code"] as? String ?? "000000"
            let expires = json?["expires_at"] as? String ?? ""
            return (code, expires)
        } catch {
            print("APIClient Fallback: Backend unreachable, returning mock pairing code.")
            return ("123456", "In 15 minutes")
        }
    }
    
    func pairChildDevice(pairingCode: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/pair-child")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["pairing_code": pairingCode, "platform": "ios"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let token = json?["access_token"] as? String {
                self.childDeviceToken = token
                return true
            }
            return false
        } catch {
            print("APIClient Fallback: Backend unreachable, simulating successful pairing.")
            self.childDeviceToken = "mock_device_token"
            return true
        }
    }
}
