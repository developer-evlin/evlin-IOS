import UIKit

/// A photo's R2 URL is stable for as long as a ChildTask lives in memory
/// (AppSync fetches it once per sync, not per view), so the same photo
/// shows up at least twice — once in a thumbnail/stack, again in the
/// full-screen viewer — and AsyncImage had no way to know that: each new
/// view instance for the same URL re-downloaded it from scratch, which is
/// what made opening the full-screen viewer feel slow right after the
/// thumbnail had already shown the same image a moment earlier. This
/// keeps a decoded copy in memory per URL for the rest of the session, so
/// only the very first view of a given photo ever pays for the download.
actor ImageCache {
    static let shared = ImageCache()
    private var cache: [String: UIImage] = [:]
    // The stack preview and the full-screen viewer both render the same
    // photoURLs at the same time (the presenting card stays mounted under
    // a fullScreenCover, not torn down) — without this, two concurrent
    // callers asking for a URL neither has cached yet each fired their own
    // independent fetch, doubling load on the same host right as the
    // gallery opens. Tracking the in-flight task per URL means the second
    // caller just awaits the first one's result instead.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for key: String) -> UIImage? { cache[key] }

    /// Loads (from cache, an already in-flight fetch, or a fresh request)
    /// and caches the result. Returns nil — logging why — on anything that
    /// isn't a decodable image, rather than the old silent single
    /// `UIImage(data:)` check that couldn't tell a real network failure
    /// apart from R2 handing back an expired-signature error page.
    func load(_ url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    print("ImageCache: \(url.path) returned HTTP \(http.statusCode)")
                    return nil
                }
                guard let image = UIImage(data: data) else {
                    print("ImageCache: \(url.path) response (\(data.count) bytes) wasn't a decodable image")
                    return nil
                }
                return image
            } catch {
                print("ImageCache: \(url.path) failed: \(error.localizedDescription)")
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { cache[key] = result }
        return result
    }
}
