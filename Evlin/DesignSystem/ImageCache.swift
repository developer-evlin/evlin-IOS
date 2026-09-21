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

    func image(for key: String) -> UIImage? { cache[key] }
    func set(_ image: UIImage, for key: String) { cache[key] = image }
}
