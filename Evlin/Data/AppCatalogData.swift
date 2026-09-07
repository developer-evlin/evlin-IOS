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
}

let mockAppCatalog: [MockApp] = [
    MockApp(name: "TikTok", bundleID: "com.zhiliaoapp.musically"),
    MockApp(name: "Instagram", bundleID: "com.burbn.instagram"),
    MockApp(name: "YouTube", bundleID: "com.google.ios.youtube"),
    MockApp(name: "Roblox", bundleID: "com.roblox.robloxmobile"),
    MockApp(name: "Snapchat", bundleID: "com.toyopagroup.picaboo"),
    MockApp(name: "Discord", bundleID: "com.hammerandchisel.discord"),
    MockApp(name: "Messages", bundleID: "com.apple.MobileSMS"),
    MockApp(name: "Safari", bundleID: "com.apple.mobilesafari"),
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
// bundle ID as a query param — used to pull each app's real icon artwork
// for the block-an-app picker. This is the one bit of networking anywhere
// in this otherwise fully offline/mock-data prototype, so there's no
// generic-icon fallback to fall back to — a failed lookup (offline, rate
// limited, unrecognized bundle ID) leaves that row's icon area empty
// rather than substituting a guess that isn't the app's actual icon.
//
// Confined to the main actor rather than a plain `enum` with `static var`
// storage: every row that shows an icon reads/writes `cache`/`inFlight`
// from its own `.task`, and a live-filtered list (typing into search)
// mounts several of them back to back — plain static vars mutated from
// multiple concurrent, actor-less Tasks is a real data race on the
// dictionaries, not just a style nit. Pinning everything here to the main
// actor is safe because the only callers (AppIconView) are SwiftUI view
// code, which is already main-actor work.
@MainActor
enum ITunesLookup {
    private struct Response: Decodable {
        var results: [Result]
        struct Result: Decodable {
            var artworkUrl512: String?
            var artworkUrl100: String?
        }
    }

    private static var cache: [String: URL] = [:]
    // A bundle ID's lookup while it's still in flight — so a second (or
    // fifth) row asking for the same app before the first request has
    // come back awaits that *same* network call instead of starting its
    // own. Without this, a fast search re-filter could fire several
    // redundant requests for one app, each one independently showing the
    // fallback tile until its own copy finished — which is what made the
    // flash reappear on nearly every keystroke instead of just once.
    private static var inFlight: [String: Task<URL?, Never>] = [:]

    // A synchronous peek at the cache — lets AppIconView seed its state
    // with an already-known icon before its first render, so re-showing a
    // row (search cleared, tab switched back) shows the real icon
    // immediately instead of flashing the fallback tile again.
    static func cachedIconURL(bundleID: String) -> URL? { cache[bundleID] }

    static func iconURL(bundleID: String) async -> URL? {
        if let cached = cache[bundleID] { return cached }
        if let pending = inFlight[bundleID] { return await pending.value }

        let task = Task<URL?, Never> {
            var comps = URLComponents(string: "https://itunes.apple.com/lookup")
            comps?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
            guard let url = comps?.url else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                guard let artwork = decoded.results.first?.artworkUrl512 ?? decoded.results.first?.artworkUrl100,
                      let resolvedURL = URL(string: artwork) else { return nil }
                return resolvedURL
            } catch {
                // Offline, rate-limited, or an unrecognized bundle ID —
                // any of these just means "no icon" to the caller.
                return nil
            }
        }
        inFlight[bundleID] = task
        let result = await task.value
        inFlight[bundleID] = nil
        if let result { cache[bundleID] = result }
        return result
    }

    // Warms every bundle ID's icon up front — the catalog is small enough
    // (8 apps) that this is cheap, and it means the picker's default list
    // and every possible search result are already resolved before a
    // parent so much as taps into the search field, instead of each new
    // row racing its own request into view.
    static func prefetchAll(bundleIDs: [String]) {
        for id in bundleIDs where cache[id] == nil && inFlight[id] == nil {
            Task { _ = await iconURL(bundleID: id) }
        }
    }
}

// Real App Store artwork, and nothing else — no generic per-app guess
// standing in for it. Given BlockTargetPicker prefetches the whole catalog
// the moment it appears, this is resolved before a row is ever likely to
// render; while genuinely unresolved (still in flight, or the lookup
// failed) the tile is just an empty outline, not a wrong-shaped stand-in.
struct AppIconView: View {
    var bundleID: String
    var size: CGFloat = 44

    @State private var iconURL: URL?

    // Seeded from the cache synchronously — a bundle ID already looked up
    // once (very likely, given the prefetch) renders its real icon on the
    // very first frame, no flash.
    @MainActor
    init(bundleID: String, size: CGFloat = 44) {
        self.bundleID = bundleID
        self.size = size
        _iconURL = State(initialValue: ITunesLookup.cachedIconURL(bundleID: bundleID))
    }

    var body: some View {
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        emptyTile
                    }
                }
            } else {
                emptyTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .task(id: bundleID) {
            // No-op when already seeded from cache — iconURL would just
            // be reassigned the identical value, but skip it outright so
            // a row that's already showing its real icon never has any
            // reason to re-render because of this.
            guard iconURL == nil else { return }
            iconURL = await ITunesLookup.iconURL(bundleID: bundleID)
        }
    }

    private var emptyTile: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(EColor.surfaceContainerHigh)
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(EColor.outlineVariant))
    }
}
