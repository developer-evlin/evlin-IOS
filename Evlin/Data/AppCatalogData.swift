import SwiftUI

// Small stand-in catalog since there's no real installed-app inventory to
// query — bundle IDs are shown because that's specifically what was asked
// for, matching how Evlin-iOS's own disambiguation cards (AppControlCard's
// app_store_disambiguation) label each candidate. Shared (not private to
// one screen) because both ScreenChat's one-off "Block an app" card and
// ScreenProfile's standing "Blocked Apps" rule pick from the same catalog —
// the same app list should look identical wherever a parent picks from it.
struct MockApp: Identifiable {
    let id = UUID()
    var name: String
    var bundleID: String
    var icon: String
    var color: Color
}

let mockAppCatalog: [MockApp] = [
    MockApp(name: "TikTok", bundleID: "com.zhiliaoapp.musically", icon: "music.note", color: .black),
    MockApp(name: "Instagram", bundleID: "com.burbn.instagram", icon: "camera.fill", color: Color(hex: "E1306C")),
    MockApp(name: "YouTube", bundleID: "com.google.ios.youtube", icon: "play.rectangle.fill", color: .red),
    MockApp(name: "Roblox", bundleID: "com.roblox.robloxmobile", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockApp(name: "Snapchat", bundleID: "com.toyopagroup.picaboo", icon: "camera.fill", color: Color(hex: "FFFC00")),
    MockApp(name: "Discord", bundleID: "com.hammerandchisel.discord", icon: "bubble.left.and.bubble.right.fill", color: Color(hex: "5865F2")),
    MockApp(name: "Messages", bundleID: "com.apple.MobileSMS", icon: "message.fill", color: .green),
    MockApp(name: "Safari", bundleID: "com.apple.mobilesafari", icon: "safari.fill", color: .blue),
]

// Mirrors LockListManagerView's real Apps/Categories split (Views/Settings/
// LockListManagerView.swift) — blocking a whole category, not just named
// apps, is a real option there.
struct MockCategory: Identifiable {
    let id = UUID()
    var name: String
    var icon: String
    var color: Color
}

let mockCategoryCatalog: [MockCategory] = [
    MockCategory(name: "Social Media", icon: "person.2.fill", color: Color(hex: "E1306C")),
    MockCategory(name: "Games", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockCategory(name: "Entertainment", icon: "play.rectangle.fill", color: .red),
    MockCategory(name: "Messaging", icon: "message.fill", color: .green),
]

// The App Store's own lookup endpoint — public, unauthenticated, just the
// bundle ID as a query param — used only to pull each app's real icon
// artwork for the block-an-app picker so a parent recognizes TikTok/
// Instagram/etc. by their actual icon instead of a generic SF Symbol
// standing in for it. This is the one bit of networking anywhere in this
// otherwise fully offline/mock-data prototype, so a failed or slow lookup
// (no connection, rate limit, unrecognized bundle ID) just falls back to
// that same SF Symbol tile rather than leaving a blank space.
enum ITunesLookup {
    private struct Response: Decodable {
        var results: [Result]
        struct Result: Decodable {
            var artworkUrl512: String?
            var artworkUrl100: String?
        }
    }

    private static var cache: [String: URL] = [:]

    static func iconURL(bundleID: String) async -> URL? {
        if let cached = cache[bundleID] { return cached }
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let artwork = decoded.results.first?.artworkUrl512 ?? decoded.results.first?.artworkUrl100,
                  let iconURL = URL(string: artwork) else { return nil }
            cache[bundleID] = iconURL
            return iconURL
        } catch {
            return nil
        }
    }
}

// Real App Store artwork once the lookup resolves; the same colored-SF-
// Symbol tile every row already had otherwise (still shown immediately, not
// a spinner, so a slow/offline lookup never reads as broken).
struct AppIconView: View {
    var bundleID: String
    var fallbackIcon: String
    var fallbackColor: Color
    var size: CGFloat = 44

    @State private var iconURL: URL?

    var body: some View {
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallbackTile
                    }
                }
            } else {
                fallbackTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .task(id: bundleID) { iconURL = await ITunesLookup.iconURL(bundleID: bundleID) }
    }

    private var fallbackTile: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(fallbackColor)
            .overlay(Image(systemName: fallbackIcon).font(.system(size: size * 0.4)).foregroundStyle(.white))
    }
}
