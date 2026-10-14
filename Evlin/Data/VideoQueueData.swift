import Foundation

/// Today's videos and video settings, per child, from the backend.
///
/// Refreshed by AppSync on every sync (so a live update — the parent
/// approving a card, the kid finishing a video — reaches the other device),
/// and directly after this device's own writes. The server owns what's left
/// of the allowance; the kid's player only adds what it's playing right now
/// on top of the last answer.
@MainActor @Observable
final class VideoQueueStore {
    static let shared = VideoQueueStore()

    private(set) var queues: [String: ApiVideoQueue] = [:]
    private(set) var profiles: [String: ApiVideoProfile] = [:]

    func queue(_ childId: String) -> ApiVideoQueue? { queues[childId] }
    func profile(_ childId: String) -> ApiVideoProfile? { profiles[childId] }

    /// A failure keeps what was there: a dropped connection shouldn't empty
    /// a kid's list mid-afternoon.
    func refresh(childId: String, includeProfile: Bool = false) async {
        if let q = try? await APIClient.shared.fetchVideoQueue(childId: childId) { queues[childId] = q }
        if includeProfile || profiles[childId] == nil,
           let p = try? await APIClient.shared.fetchVideoProfile(childId: childId) {
            profiles[childId] = p
        }
    }

    // MARK: Parent

    func approve(childId: String, videos: [VideoSuggestion], replace: Bool) async throws {
        queues[childId] = try await APIClient.shared.addToVideoQueue(childId: childId, videos: videos, replace: replace)
    }

    func remove(childId: String, itemId: String) async throws {
        try await APIClient.shared.removeFromVideoQueue(itemId: itemId)
        await refresh(childId: childId)
    }

    func reorder(childId: String, itemIds: [String]) async throws {
        queues[childId] = try await APIClient.shared.reorderVideoQueue(childId: childId, itemIds: itemIds)
    }

    func save(_ profile: ApiVideoProfile) async throws {
        profiles[profile.childId] = try await APIClient.shared.updateVideoProfile(
            childId: profile.childId,
            allowedCategories: profile.allowedCategories,
            blockedKeywords: profile.blockedKeywords,
            allowedChannels: profile.allowedChannels,
            blockedChannels: profile.blockedChannels,
            dailyMinutes: profile.dailyMinutes,
            maxVideoMinutes: profile.maxVideoMinutes)
        await refresh(childId: profile.childId)  // the daily minutes change what's left
    }

    /// Keeps a channel's videos out of future suggestions.
    func blockChannel(childId: String, id: String, title: String) async throws {
        if profiles[childId] == nil { await refresh(childId: childId, includeProfile: true) }
        guard var p = profiles[childId], !id.isEmpty else { return }
        if !p.blockedChannels.contains(where: { $0.id == id }) {
            p.blockedChannels.append(ApiVideoChannel(id: id, title: title))
        }
        p.allowedChannels.removeAll { $0.id == id }
        try await save(p)
    }

    // MARK: Kid

    func reportProgress(childId: String, itemId: String, watchedSeconds: Int, completed: Bool) async {
        _ = try? await APIClient.shared.reportVideoProgress(itemId: itemId, watchedSeconds: watchedSeconds,
                                                            completed: completed)
        await refresh(childId: childId)
    }
}

/// Display helpers shared by the parent and kid views.
enum VideoFormat {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    static func minutesLeft(_ seconds: Int) -> String {
        let m = Int((Double(max(0, seconds)) / 60).rounded(.up))
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    static func categoryName(_ key: String) -> String {
        key.isEmpty ? "" : key.prefix(1).uppercased() + key.dropFirst()
    }

    static func categoryIcon(_ key: String) -> String {
        switch key {
        case "science": return "flask.fill"
        case "art": return "paintbrush.pointed.fill"
        case "math": return "number"
        case "nature": return "leaf.fill"
        case "kitchen": return "fork.knife"
        case "music": return "music.note"
        case "reading": return "book.fill"
        case "mindful": return "wind"
        default: return "play.rectangle.fill"
        }
    }
}
