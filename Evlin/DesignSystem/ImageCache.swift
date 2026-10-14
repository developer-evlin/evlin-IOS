import UIKit
import ImageIO
import CryptoKit

/// Submission photos, downloaded once and kept.
///
/// - Keyed by the photo's R2 object path (the URL without its query): every
///   sync hands out a freshly signed link to the same photo, so the full URL
///   changes while the photo doesn't.
/// - Two layers: decoded images in memory, and the downloaded bytes on disk
///   (Caches), so a relaunch shows photos already seen without fetching
///   them again.
/// - Today's photos only, on both phones: the app only ever shows today's
///   submissions, so a photo last used on an earlier day is deleted the
///   first time the cache is used on a new day.
/// - Decoded at display size, off the main thread (ImageIO thumbnails), never
///   at the photo's full camera resolution.
/// - One download per photo at a time: the card and the full-screen viewer
///   asking together share it.
actor ImageCache {
    static let shared = ImageCache()

    // Readable synchronously, so a view can start with an already-loaded
    // photo on its first frame instead of flashing its placeholder.
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    // Large enough for a full-screen photo on any iPhone or iPad.
    private static let maxPixelSize: CGFloat = 2048

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EvlinPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // The day the cache was last cleared for; a new day clears it again.
    private var prunedFor: Date?

    private static func key(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil
        return parts?.string ?? url.absoluteString
    }

    private static func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    nonisolated static func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: key(url) as NSString)
    }

    /// Starts loading photos in the background, so they're ready when shown.
    nonisolated func prefetch(_ urlStrings: [String]) {
        let urls = urlStrings.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls { _ = await ImageCache.shared.load(url) }
        }
    }

    func load(_ url: URL) async -> UIImage? {
        let key = Self.key(url)
        if let cached = Self.memory.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }
        pruneForNewDay()

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let file = Self.file(for: key)
            if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
                // Marks it as recently used, for the disk clean-up.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return image
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    print("ImageCache: \(url.path) returned HTTP \(http.statusCode)")
                    return nil
                }
                guard let image = Self.decode(data) else {
                    print("ImageCache: \(url.path) response (\(data.count) bytes) wasn't a decodable image")
                    return nil
                }
                try? data.write(to: file, options: .atomic)
                return image
            } catch {
                print("ImageCache: \(url.path) failed: \(error.localizedDescription)")
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            Self.memory.setObject(result, forKey: key as NSString, cost: cost)
        }
        return result
    }

    /// Decodes at no more than maxPixelSize on its longer side, fully
    /// decoded now so drawing it later costs nothing.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// On the first use of a new day: drops photos last used before today,
    /// from disk and from memory.
    private func pruneForNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        guard prunedFor != today else { return }
        let isFirstRun = prunedFor == nil
        prunedFor = today
        if !isFirstRun { Self.memory.removeAllObjects() }
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let used = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if used < today { try? fm.removeItem(at: file) }
            }
        }
    }
}
