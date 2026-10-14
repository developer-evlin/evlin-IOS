import SwiftUI
import UIKit

/// Evlin's app catalog, from the backend (GET /apps) — the same rows the AI
/// resolves names against and blocks point at, so the picker can never offer
/// an app the rest of the system doesn't know. Shared because every place a
/// parent picks an app should show the identical list.
@MainActor @Observable
final class AppCatalog {
    static let shared = AppCatalog()
    private(set) var apps: [ApiApp] = []
    private var loading: Task<Void, Never>?

    /// Loads once per launch; concurrent callers share the one request. A
    /// failure leaves the list empty so the next caller tries again.
    func load() async {
        if !apps.isEmpty { return }
        if let loading { return await loading.value }
        let task = Task {
            if let fetched = try? await APIClient.shared.fetchAppCatalog() { apps = fetched }
        }
        loading = task
        await task.value
        loading = nil
    }

    func app(id: String) -> ApiApp? { apps.first { $0.id == id } }
}

// The App Store's public search endpoint, queried by the catalog app's name,
// used to pull each app's real icon artwork for the block-an-app picker. A
// name search can return other apps, so only a result whose own name is
// that app (or starts with it: "Spotify - Music and Podcasts") is accepted;
// built-ins that aren't on the store (Messages, Safari) simply get no icon. This is the one bit of networking anywhere
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
            var trackName: String?
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
    static func cachedIconURL(appName: String) -> URL? { cache[appName] }

    static func iconURL(appName: String) async -> URL? {
        if let cached = cache[appName] { return cached }
        if let pending = inFlight[appName] { return await pending.value }

        let task = Task<URL?, Never> {
            var comps = URLComponents(string: "https://itunes.apple.com/search")
            comps?.queryItems = [
                URLQueryItem(name: "term", value: appName),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = comps?.url else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                let wanted = normalized(appName)
                let match = decoded.results.first { result in
                    guard let name = result.trackName.map(normalized) else { return false }
                    return name == wanted || name.hasPrefix(wanted + " ")
                }
                guard let artwork = match?.artworkUrl512 ?? match?.artworkUrl100,
                      let resolvedURL = URL(string: artwork) else { return nil }
                return resolvedURL
            } catch {
                // Offline or rate-limited — just "no icon" to the caller.
                return nil
            }
        }
        inFlight[appName] = task
        let result = await task.value
        inFlight[appName] = nil
        if let result { cache[appName] = result }
        return result
    }

    /// Case, accents and punctuation don't make a different app: "Pokémon
    /// GO" is "pokemon go", "Disney+" is "disney plus".
    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "+", with: " plus ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Warms every bundle ID's icon up front — the catalog is small enough
    // (a few dozen apps) that this is cheap, and it means the picker's default list
    // and every possible search result are already resolved before a
    // parent so much as taps into the search field, instead of each new
    // row racing its own request into view. Warms the actual image bytes
    // too (IconImageCache), not just the URL — resolving the URL alone
    // still left the first render of every row to pay for its own image
    // download.
    static func prefetchAll(appNames: [String]) {
        for name in appNames where cache[name] == nil && inFlight[name] == nil {
            Task {
                guard let url = await iconURL(appName: name) else { return }
                _ = await IconImageCache.image(for: url)
            }
        }
    }
}

// ITunesLookup only caches the *resolved artwork URL* for a bundle ID —
// it says nothing about the image bytes themselves. AsyncImage has no
// cache of its own shared across view instances, so without this, every
// time a row got filtered out of the picker's search results and back in
// (a fresh AppIconView instance each time) it re-downloaded the same
// full-size artwork from Apple's CDN from scratch — several times a
// second while typing, per a real Sentry breadcrumb log showing the same
// handful of icon URLs each fetched 3-4 times within a few seconds. This
// caches the decoded image itself, keyed by URL, with the same
// cache-plus-in-flight-coalescing shape as ITunesLookup below it, so a
// bundle ID's artwork is only ever downloaded once per app launch no
// matter how many times a row for it gets created.
@MainActor
enum IconImageCache {
    // NSCache evicts entries automatically under memory pressure,
    // preventing the unbounded growth of the old [URL: UIImage] dict.
    private static let cache = NSCache<NSURL, UIImage>()
    private static var inFlight: [URL: Task<UIImage?, Never>] = [:]

    static func cachedImage(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let pending = inFlight[url] { return await pending.value }

        let task = Task<UIImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return UIImage(data: data)
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { cache.setObject(result, forKey: url as NSURL) }
        return result
    }
}

// Real App Store artwork, and nothing else — no generic per-app guess
// standing in for it. Given BlockTargetPicker prefetches the whole catalog
// the moment it appears, this is resolved before a row is ever likely to
// render; while genuinely unresolved (still in flight, or the lookup
// failed) the tile is just an empty outline, not a wrong-shaped stand-in.
struct AppIconView: View {
    var appName: String
    var size: CGFloat = 44

    @State private var iconURL: URL?
    @State private var image: UIImage?

    // Seeded from both caches synchronously — a bundle ID already looked
    // up and downloaded once (very likely, given the prefetch) renders its
    // real icon on the very first frame, no flash and no redundant fetch,
    // regardless of how many times this view gets torn down and recreated
    // (e.g. filtered out of search results and back in).
    @MainActor
    init(appName: String, size: CGFloat = 44) {
        self.appName = appName
        self.size = size
        let seededURL = ITunesLookup.cachedIconURL(appName: appName)
        _iconURL = State(initialValue: seededURL)
        _image = State(initialValue: seededURL.flatMap { IconImageCache.cachedImage(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                emptyTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .task(id: appName) {
            // No-op when already seeded from cache — skip outright so a
            // row that's already showing its real icon never has any
            // reason to re-render because of this.
            guard image == nil else { return }
            let resolvedURL: URL?
            if let iconURL { resolvedURL = iconURL } else { resolvedURL = await ITunesLookup.iconURL(appName: appName) }
            guard let resolvedURL else { return }
            iconURL = resolvedURL
            image = await IconImageCache.image(for: resolvedURL)
        }
    }

    private var emptyTile: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(EColor.surfaceContainerHigh)
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(EColor.outlineVariant))
    }
}
