import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A kid's photos, from the moment they're taken until R2 has them and the
/// task they were sent in with has been accepted (2026-11-19).
///
/// - Taken, a photo is shrunk (HEIC, 1600 px, no camera metadata), saved in
///   Application Support (which iOS never clears, unlike Caches) and queued
///   as an "uploadPhoto" PendingWrite named by its own id (`photoId`), the
///   server's submission id too, so a retry never makes a second photo.
/// - Its upload starts at once: a slot on the server (one request, a link
///   signed for the file's exact size), then the file itself, carried by
///   iOS (`BackgroundUploads`), so it finishes with the app closed.
/// - Send ("All done!") is an outbox write naming the photos. The outbox
///   holds it until they're up, and the server counts each photo only once
///   R2 has it, in the same commit that sends the task in. A photo the
///   server says it doesn't have is uploaded again and Send repeated.
/// - Retries come from the outbox (launch, foreground, network back, every
///   sync), not from the task's screen being open.
@MainActor @Observable
final class PhotoUploads {
    static let shared = PhotoUploads()

    enum State { case uploading, uploaded, failed }

    /// By photo id, for the task screen (a failed upload shows its retry).
    private(set) var states: [String: State] = [:]

    /// Writes whose slot or file is on its way now (by write id).
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Photos still being shrunk and saved (by photo id).
    @ObservationIgnored private var preparing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failedTries = 0
    @ObservationIgnored private var tidied = false

    /// A photo the same server refused this many times (it never had it)
    /// is given up on, so Send isn't repeated for ever.
    private static let maxRefusals = 5

    func state(of photoId: String) -> State? { states[photoId] }

    // MARK: - Taking a photo

    /// Starts a photo on its way the moment it's taken. Returns its id at
    /// once; the shrinking runs off the main thread.
    func add(_ image: UIImage, occurrenceId: String, taskId: String, childId: String) -> String {
        let photoId = APIClient.Write.newId()
        states[photoId] = .uploading
        preparing[photoId] = Task {
            defer { preparing[photoId] = nil }
            let encoded = await Task.detached(priority: .userInitiated) { PhotoCompression.encodeForUpload(image) }.value
            guard let encoded, let file = Self.save(encoded.data, ext: encoded.ext) else {
                states[photoId] = .failed
                return
            }
            var slot = APIClient.Write.photoSlot(occurrenceId: occurrenceId, photoId: photoId,
                                                 contentType: encoded.contentType, bytes: encoded.data.count)
            if let local = LocalStore.shared.localOccurrence(id: occurrenceId) {
                slot.occurrence = .init(localId: occurrenceId, childId: childId, taskId: taskId, dueDate: local.dueDate)
            }
            let write = PendingWrite(childId: childId, kind: "uploadPhoto", occurrenceId: occurrenceId,
                                     localFilePath: file.path, contentType: encoded.contentType)
            write.photoId = photoId
            write.payload = try? JSONEncoder().encode(slot)
            LocalStore.shared.queueWrite(write)
            // The Demo sends nothing: its photos count as up at once.
            if DemoMode.isBuild {
                write.uploadedAt = Date()
                LocalStore.shared.saveChanges()
                states[photoId] = .uploaded
                return
            }
            run()
        }
        return photoId
    }

    /// Waits until these photos are saved on the device (Send can't name a
    /// photo still being shrunk).
    func ready(_ photoIds: [String]) async {
        for id in photoIds { await preparing[id]?.value }
    }

    /// A photo taken off the task before it was sent in.
    func discard(_ photoId: String) {
        preparing[photoId]?.cancel()
        states[photoId] = nil
        for write in LocalStore.shared.uploadWrites() where write.photoId == photoId { remove(write) }
    }

    /// The kid's retry on a photo that didn't go.
    func retryNow() {
        failedTries = 0
        run()
    }

    // MARK: - Sending

    /// Photos still to upload, or uploaded and still to confirm.
    var hasWork: Bool { !LocalStore.shared.uploadWrites().isEmpty }

    /// Starts whatever isn't on its way yet. Safe to call often: the
    /// outbox calls it on every drain.
    func run() {
        guard !DemoMode.isBuild else { return }
        tidyOnce()
        let writes = LocalStore.shared.uploadWrites()
        guard !writes.isEmpty else { return }
        // Made again after a relaunch, so uploads iOS finished while the
        // app was closed report in.
        _ = BackgroundUploads.shared.session
        let named = namedBySend()
        for write in writes where !inFlight.contains(write.id) {
            if write.photoId == nil { adoptOlderUpload(write) }
            guard let photoId = write.photoId else { continue }
            if write.uploadedAt == nil {
                startUpload(write)
            } else if !named.contains(photoId) {
                confirm(write)
            }
        }
    }

    /// Send waits for these: a photo it names that isn't up yet.
    func holds(_ request: WriteRequest) -> Bool {
        guard let ids = request.photoIds, !ids.isEmpty else { return false }
        let wanted = Set(ids)
        if wanted.contains(where: { preparing[$0] != nil }) { return true }
        return LocalStore.shared.uploadWrites().contains { write in
            write.uploadedAt == nil && write.photoId.map(wanted.contains) == true
        }
    }

    /// The server accepted a Send that named photos. Those it has are done
    /// here; any it doesn't are uploaded again and the Send repeated.
    func sendAccepted(_ request: WriteRequest, answer: Data, childId: String, label: String) {
        guard let ids = request.photoIds, !ids.isEmpty else { return }
        let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        let missing = Set(((reply?["missing_photo_ids"] as? [String]) ?? []).map { $0.lowercased() })
        var again = false
        for write in LocalStore.shared.uploadWrites() {
            guard let photoId = write.photoId, ids.contains(photoId) else { continue }
            if missing.contains(photoId.lowercased()) {
                write.attempts += 1
                if write.attempts >= Self.maxRefusals {
                    print("PhotoUploads: the server never had photo \(photoId); given up")
                    remove(write)
                    continue
                }
                write.uploadedAt = nil
                again = true
            } else {
                states[photoId] = .uploaded
                remove(write)
            }
        }
        LocalStore.shared.saveChanges()
        if again {
            var repeated = request
            repeated.occurrence = nil
            Outbox.send(repeated, childId: childId, label: label)
            run()
        }
    }

    // MARK: - One photo

    private func startUpload(_ write: PendingWrite) {
        guard let photoId = write.photoId, let slot = write.request,
              let path = write.localFilePath, let contentType = write.contentType else { return remove(write) }
        guard FileManager.default.fileExists(atPath: path) else {
            print("PhotoUploads: photo \(photoId)'s file is gone; given up")
            states[photoId] = .failed
            return remove(write)
        }
        let writeId = write.id
        inFlight.insert(writeId)
        if states[photoId] != .failed { states[photoId] = .uploading }
        Task {
            do {
                let sent = try await Outbox.resolve(slot)
                let answer = try await APIClient.shared.send(sent)
                guard let reply = try JSONSerialization.jsonObject(with: answer) as? [String: Any],
                      let link = (reply["upload_url"] as? String).flatMap(URL.init(string:)) else {
                    throw APIFailure(status: 500, detail: "No upload link")
                }
                BackgroundUploads.shared.upload(file: URL(fileURLWithPath: path), to: link,
                                                contentType: contentType, writeId: writeId)
                // The rest arrives in finished(writeId:status:error:).
            } catch let failure as APIFailure where [403, 404, 409, 422].contains(failure.status) {
                // The task's gone, or the photo can't be taken (too big):
                // nothing a retry would change.
                print("PhotoUploads: photo \(photoId) refused (\(failure.status)); given up")
                inFlight.remove(writeId)
                if let write = LocalStore.shared.pendingWrite(id: writeId) { remove(write) }
                states[photoId] = .failed
            } catch {
                inFlight.remove(writeId)
                failed(writeId: writeId, photoId: photoId)
            }
        }
    }

    /// iOS finished carrying a file (now, or while the app was closed).
    func finished(writeId: String?, status: Int?, error: Error?) {
        guard let writeId else { return }
        inFlight.remove(writeId)
        guard let write = LocalStore.shared.pendingWrite(id: writeId), let photoId = write.photoId else { return }
        guard error == nil, let status, (200..<300).contains(status) else {
            // 403: the link ran out (an hour offline); the next try asks
            // for a fresh one.
            print("PhotoUploads: photo \(photoId) upload failed (\(status.map(String.init) ?? "\(String(describing: error))"))")
            return failed(writeId: writeId, photoId: photoId)
        }
        write.uploadedAt = Date()
        LocalStore.shared.saveChanges()
        states[photoId] = .uploaded
        failedTries = 0
        if namedBySend().contains(photoId) {
            // The Send waiting on it can go now.
            Task { await Outbox.drain() }
        } else {
            confirm(write)
        }
    }

    /// Up, with no Send naming it yet (taken but not sent in, or an
    /// upload from before photos were named by Send): the server checks
    /// R2 now, so it's never left half done; Send later finds it there.
    private func confirm(_ write: PendingWrite) {
        guard let photoId = write.photoId else { return }
        let writeId = write.id
        inFlight.insert(writeId)
        Task {
            defer { inFlight.remove(writeId) }
            do {
                try await APIClient.shared.completeSubmission(id: photoId)
                if let write = LocalStore.shared.pendingWrite(id: writeId) { remove(write) }
            } catch let failure as APIFailure where failure.status == 409 {
                // R2 doesn't have it after all: upload it again.
                LocalStore.shared.pendingWrite(id: writeId)?.uploadedAt = nil
                LocalStore.shared.saveChanges()
                scheduleRetry()
            } catch let failure as APIFailure where [403, 404].contains(failure.status) {
                if let write = LocalStore.shared.pendingWrite(id: writeId) { remove(write) }
            } catch {
                scheduleRetry()
            }
        }
    }

    /// Not reaching R2 or the server: tried again, never given up on (a
    /// day offline is still a photo to send). `attempts` counts only the
    /// server saying it never got the photo.
    private func failed(writeId: String, photoId: String) {
        states[photoId] = .failed
        scheduleRetry()
    }

    /// 2, 4, 8 … seconds, up to a minute, while the app is open. Coming
    /// back online and every sync retry at once (they drain the outbox).
    private func scheduleRetry() {
        failedTries += 1
        let seconds = min(60, 1 << min(failedTries, 6))
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            run()
        }
    }

    // MARK: - Housekeeping

    /// Photo ids named by a Send still in the outbox.
    private func namedBySend() -> Set<String> {
        Set(LocalStore.shared.pendingRequests().flatMap { $0.request?.photoIds ?? [] })
    }

    private func remove(_ write: PendingWrite) {
        if let path = write.localFilePath { try? FileManager.default.removeItem(atPath: path) }
        LocalStore.shared.removePendingWrite(write)
    }

    /// An upload queued by an older version (its own screen sent it, with
    /// no id of its own): given an id and a slot, so it goes the same way.
    private func adoptOlderUpload(_ write: PendingWrite) {
        let photoId = APIClient.Write.newId()
        let size = write.localFilePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
        let contentType = write.contentType ?? "image/jpeg"
        write.photoId = photoId
        write.contentType = contentType
        write.payload = try? JSONEncoder().encode(APIClient.Write.photoSlot(
            occurrenceId: write.occurrenceId, photoId: photoId, contentType: contentType, bytes: size))
        LocalStore.shared.saveChanges()
    }

    /// Once a launch: a photo for a day long gone (its task has moved on)
    /// is dropped with its file.
    private func tidyOnce() {
        guard !tidied else { return }
        tidied = true
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        for write in LocalStore.shared.uploadWrites() where write.createdAt < cutoff { remove(write) }
    }

    // MARK: - Files

    /// Application Support, not Caches: iOS empties Caches when storage
    /// runs low, which used to lose a kid's photo before it went.
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private static func save(_ data: Data, ext: String) -> URL? {
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("PhotoUploads: couldn't save a photo: \(error)")
            return nil
        }
    }
}

/// The file transfers themselves, carried by iOS: a background session
/// keeps uploading after the app is suspended or closed by the system, and
/// waits for the network by itself. Started while the app is on screen, so
/// iOS sends at once rather than when it suits it. (A force-quit cancels
/// them; the outbox starts them again at the next launch.)
final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploads()
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.evlin.ios") + ".photo-uploads"

    /// iOS's call to say the transfers it carried while the app was closed
    /// are done (AppDelegate), answered once their results are in.
    var finishEvents: (() -> Void)?

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func upload(file: URL, to link: URL, contentType: String, writeId: String) {
        session.getAllTasks { [self] tasks in
            // Already being carried (started before the app was relaunched).
            if tasks.contains(where: { $0.taskDescription == writeId && $0.state == .running }) { return }
            var request = URLRequest(url: link)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = writeId
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let writeId = task.taskDescription
        Task { @MainActor in PhotoUploads.shared.finished(writeId: writeId, status: status, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            finishEvents?()
            finishEvents = nil
        }
    }
}
