import SwiftUI
import UIKit

private let taskDetailBottomAnchorID = "task-detail-bottom-anchor"

/// One photo a kid has captured for this task. `image` is set the moment
/// it's taken (so the tile shows something real immediately, not a
/// placeholder); `downloadURL` is set instead when this photo came from
/// reopening an already-submitted task (the backend's copy — there's no
/// local UIImage left once the app has relaunched). `submissionId` and
/// `uploadState` track the real upload to the backend, independent of the
/// local capture.
private struct CapturedPhoto: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage?
    var downloadURL: String?
    var submissionId: String?
    var uploadState: UploadState = .idle

    enum UploadState: Equatable { case idle, uploading, uploaded, failed }

    static func == (l: CapturedPhoto, r: CapturedPhoto) -> Bool { l.id == r.id }
}

struct TaskDetailView: View {
    let task: KidTask
    var onComplete: (_ photoCount: Int, _ note: String?, _ hasVoiceNote: Bool) -> Void
    var onRequestBypass: (String, Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [CapturedPhoto] = []
    @State private var showCamera = false
    @State private var note = ""
    @State private var hasVoiceNote = false
    @State private var submitted: Bool
    // Distinguishes "just tapped All done! this session" (a brief fresh-
    // confirmation beat) from "reopened an already-done task" (goes
    // straight to the plain recap) — both share the same photo grid/note
    // below, only the header card differs. Neither one tells the kid their
    // evidence is still pending review — that's the parent's business, not
    // something to make the kid sit and wonder about.
    @State private var justSubmitted = false
    @State private var showBypassSheet = false
    @State private var bypassSent = false
    @State private var viewerIndex: Int?
    // A form/detail screen, same reading-shaped treatment as the rest of
    // the kid side — caps to KidAdaptive's content column instead of
    // stretching this full-screen cover's padding(20) across the iPad's
    // whole width, and the photo grid grows more columns instead of 3
    // fixed ones stretching wider.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }
    // Regular's minimum/maximum used to both sit close to compact's (130/160)
    // — fine for tile size, but against the 760pt-capped content column that
    // fits 5 of them per row, so a typical 5-6 photo submission stranded the
    // "Add photo" tile alone on its own row with four empty column-widths of
    // blank space beside it. Widening both bounds drops that to 4 per row
    // (a smaller, less noticeable 2-tile trailing gap) and makes each tile a
    // bit bigger besides, in keeping with iPad getting more than a
    // same-sized-but-more-of-it version of the phone layout.
    private var photoGridColumns: [GridItem] { [GridItem(.adaptive(minimum: kid.of(90, 150), maximum: kid.of(160, 190)), spacing: 10)] }

    // Seeds submitted/note from the task itself — without this, a kid
    // reopening an already-done task would land back on the "take a photo"
    // capture flow instead of seeing what they actually turned in, since
    // this state otherwise starts empty every time this view is freshly
    // created. Photos themselves load separately (see .task below) — a
    // reopened task has no local UIImage any more, only what the backend
    // has, so they can't be seeded synchronously here.
    init(task: KidTask, onComplete: @escaping (_ photoCount: Int, _ note: String?, _ hasVoiceNote: Bool) -> Void, onRequestBypass: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.task = task
        self.onComplete = onComplete
        self.onRequestBypass = onRequestBypass
        _submitted = State(initialValue: task.done)
        _note = State(initialValue: task.submissionNote ?? "")
        _hasVoiceNote = State(initialValue: task.submissionHasVoiceNote)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if bypassSent {
                            bypassSentCard
                        } else if !submitted {
                            notYetSubmittedContent
                        } else {
                            submittedContent
                        }

                        // Nothing sits below "Add a note" but the (short) rest
                        // of the form, so the keyboard alone can cover it —
                        // scrolling to this anchor on keyboard-open brings the
                        // note field and "All done!" back into view instead of
                        // leaving them hidden behind it.
                        Color.clear.frame(height: 1).id(taskDetailBottomAnchorID)
                    }
                    .padding(20)
                    .kidContentColumn(kid.contentMaxWidth)
                }
                // Replaces a blanket dismissKeyboardOnTap() that used to sit
                // on this whole screen: that gesture fired on *any* tap,
                // including the tap trying to focus the note field itself —
                // the same "short tap doesn't register" fight documented on
                // RootView's own dismissKeyboardOnTap usage, here showing up
                // as the keyboard feeling glitchy to open/type into. Scroll-
                // driven dismissal only touches drags on empty scroll space,
                // never the field's own tap-to-focus.
                .scrollDismissesKeyboard(.interactively)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(taskDetailBottomAnchorID, anchor: .bottom)
                    }
                }
            }
            .background(KidTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                        .foregroundStyle(KidTheme.greenDeep)
                }
            }
        }
        // Non-interactive: this screen owns a ScrollView (and a text field),
        // so the swipe only triggers on a clearly deliberate big/fast
        // downward drag rather than fighting normal scrolling for every
        // touch — see SwipeToDismiss's own doc comment.
        .swipeToDismiss(interactive: false) { dismiss() }
        .task {
            guard let occurrenceId = task.occurrenceId else { return }
            await loadExistingSubmissions(occurrenceId: occurrenceId)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture(
                onCapture: { image in
                    showCamera = false
                    capture(image)
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { IdentifiedInt(value: $0) } },
            set: { viewerIndex = $0?.value }
        )) { wrapped in
            KidPhotoViewer(photos: photos, index: wrapped.value) { viewerIndex = nil }
        }
        // fullScreenCover, not .sheet — a .sheet always renders in compact
        // horizontal size class on iPad regardless of the actual device
        // width (confirmed empirically elsewhere in this app), so none of
        // KidAdaptive's regular-width scaling ever kicked in here: it just
        // floated as a small, tightly-packed phone-sized card in the
        // middle of a huge screen, which is what read as cluttered rather
        // than an intentional compose screen.
        .fullScreenCover(isPresented: $showBypassSheet) {
            BypassRequestSheet(
                taskTitle: task.title,
                onSend: { reason, hasVoice in
                    showBypassSheet = false
                    bypassSent = true
                    onRequestBypass(reason, hasVoice)
                },
                onCancel: { showBypassSheet = false }
            )
        }
    }

    // MARK: - Not-yet-submitted flow (capture + note + "All done!")

    @ViewBuilder private var notYetSubmittedContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(task.title)
                .font(Typography.display(28, weight: .heavy))
                .foregroundStyle(KidTheme.ink)
            Spacer()
            Circle().fill(KidTheme.green).frame(width: 44, height: 44)
                .overlay(Image(systemName: "speaker.wave.2.fill").font(.system(size: 18)).foregroundStyle(.white))
        }
        Text(task.desc)
            .font(Typography.font(16, weight: .medium))
            .foregroundStyle(KidTheme.inkSoft)
            .padding(.top, 16)

        // The list card (ScreenTabletHome) already shows a one-line preview
        // of this, but that's easy to miss on the way in — showing the full
        // note again right where the kid is about to act on it means they
        // don't have to remember or go back to reread it.
        if task.redoRequested {
            VStack(alignment: .leading, spacing: 6) {
                Label("Your parent asked for a redo", systemImage: "arrow.counterclockwise")
                    .font(Typography.font(14, weight: .heavy))
                    .foregroundStyle(Color(hex: "EA580C"))
                if let redoNote = task.redoNote, !redoNote.isEmpty {
                    Text(redoNote)
                        .font(Typography.font(14, weight: .regular))
                        .foregroundStyle(KidTheme.ink)
                }
                if task.redoHasVoiceNote {
                    Label("They also left a voice note", systemImage: "waveform")
                        .font(Typography.font(12.5, weight: .bold))
                        .foregroundStyle(Color(hex: "EA580C"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "FFEDD5"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.top, 16)
        }

        // A photo is always optional — this used to block "All done!" until
        // at least one was attached, which meant a task that never needed
        // photo evidence at all (submission_kind == "none"/"voice") still
        // forced a kid through the camera. The copy reflects that instead
        // of implying it's required.
        Text(photos.isEmpty ? "Add a photo if you'd like (optional)" : "Add another photo, or you're all set")
            .font(Typography.display(18, weight: .bold))
            .foregroundStyle(KidTheme.ink)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 32).padding(.bottom, 16)

        if photos.isEmpty {
            Button { showCamera = true } label: {
                VStack(spacing: 16) {
                    Circle().fill(KidTheme.green).frame(width: 84, height: 84)
                        .overlay(Image(systemName: "camera.fill").font(.system(size: 36, weight: .bold)).foregroundStyle(.white))
                    Text("Tap to take a photo").font(Typography.display(20, weight: .bold))
                    Text("Show us what you did").font(Typography.font(14, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .background(KidTheme.cream)
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(KidTheme.line, style: StrokeStyle(lineWidth: 2.5, dash: [7])))
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
        } else {
            LazyVGrid(columns: photoGridColumns, spacing: 10) {
                ForEach(photos) { photo in
                    KidCapturedPhotoTile(photo: photo) {
                        // Removed by identity, not position — an async
                        // upload-state update landing between render and
                        // tap could otherwise make a captured index point
                        // at the wrong photo. A retake removes and expects
                        // the kid to tap "Add another photo" again, rather
                        // than silently swapping back in — makes the retry
                        // an explicit, visible action. Also how a failed
                        // upload is cleared to try again.
                        withAnimation(.easeOut(duration: 0.15)) { photos.removeAll { $0.id == photo.id } }
                    }
                }
                Button { showCamera = true } label: {
                    // GeometryReader, not aspectRatio directly on the VStack — a
                    // VStack of just an icon + label has real intrinsic content
                    // size, so aspectRatio(.fit) sizes itself to fit THAT (a tiny
                    // square) rather than expanding to the grid column's proposed
                    // width, no matter what order .frame(maxWidth:.infinity) is
                    // applied in. GeometryReader itself has no intrinsic size, so
                    // aspectRatio on it is forced to size from the column's
                    // proposed width instead.
                    GeometryReader { geo in
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(KidTheme.green)
                            Text("Add photo")
                                .font(Typography.font(11.5, weight: .bold))
                                .foregroundStyle(KidTheme.inkSoft)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(KidTheme.cream)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KidTheme.line, style: StrokeStyle(lineWidth: 2, dash: [6])))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                }
                .buttonStyle(.plain)
            }
        }

        Text("Add a note (optional)")
            .font(Typography.display(15.5, weight: .bold))
            .foregroundStyle(KidTheme.ink)
            .padding(.top, 22).padding(.bottom, 8)

        TextField("Tell your parent anything about it…", text: $note, axis: .vertical)
            .font(Typography.font(15, weight: .regular))
            .lineLimit(2...4)
            .padding(14)
            .background(KidTheme.cream)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KidTheme.line, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))

        KidVoiceRecorderButton(hasVoiceNote: $hasVoiceNote)
            .padding(.top, 10)

        // Elevated "kid" pill per the style guide: mascot green face, a
        // solid green-deep base for the 3D lift — a duplicate offset
        // rectangle behind the face, not a `.shadow()` (which would also
        // shadow the label text itself, ghosting a second copy of it
        // below). Never disabled by photo count any more — a photo is
        // optional, so "All done!" always has to be reachable.
        Button { submitted = true; justSubmitted = true } label: {
            Text("All done!")
                .font(Typography.display(20, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 20).fill(KidTheme.greenDeep).offset(y: 5)
                        RoundedRectangle(cornerRadius: 20).fill(KidTheme.green)
                    }
                    // Flattened into one layer first so any future
                    // press/disabled dimming can't split the two
                    // rectangles apart into a smeared double edge.
                    .compositingGroup()
                )
        }
        .buttonStyle(.plain)
        .padding(.top, photos.isEmpty ? 18 : 22)
        .padding(.bottom, 5)

        Button { showBypassSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Can't do this today?")
                    .font(Typography.font(14, weight: .bold))
            }
            .foregroundStyle(KidTheme.lavenderText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Submitted flow (recap, no "waiting for parent" framing)

    @ViewBuilder private var submittedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(justSubmitted ? "Evidence submitted 🎉" : "All done! ✅")
                .font(Typography.display(21, weight: .heavy)).foregroundStyle(KidTheme.ink)
            Text(justSubmitted ? "Nice work! Here's what you turned in." : "Here's what you turned in for this one.")
                .font(Typography.font(14.5, weight: .regular)).foregroundStyle(KidTheme.inkSoft)
        }
        .padding(22)
        .background(KidTheme.cream)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(KidTheme.ink, lineWidth: 2.5))
        .clipShape(RoundedRectangle(cornerRadius: 20))

        if !photos.isEmpty {
            Text("Your photo\(photos.count == 1 ? "" : "s")")
                .font(Typography.display(16, weight: .bold))
                .foregroundStyle(KidTheme.ink)
                .padding(.top, 20).padding(.bottom, 10)

            LazyVGrid(columns: photoGridColumns, spacing: 10) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { viewerIndex = index } label: {
                        SubmittedPhotoThumbnail(photo: photo)
                            .aspectRatio(3.0/4.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KidTheme.line, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your note")
                    .font(Typography.display(16, weight: .bold))
                    .foregroundStyle(KidTheme.ink)
                Text(note)
                    .font(Typography.font(14.5, weight: .regular))
                    .foregroundStyle(KidTheme.inkSoft)
            }
            .padding(.top, 20)
        }

        if hasVoiceNote {
            Label("Voice note attached", systemImage: "waveform")
                .font(Typography.font(13.5, weight: .bold))
                .foregroundStyle(KidTheme.lavenderText)
                .padding(.top, 10)
        }

        Button {
            if justSubmitted { onComplete(photos.count, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note, hasVoiceNote) }
            dismiss()
        } label: {
            Text("Back to today")
                .font(Typography.font(18, weight: .heavy))
                .foregroundStyle(KidTheme.ink)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.line, lineWidth: 2))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.top, 20)
    }

    // MARK: - Real capture + upload

    private func capture(_ image: UIImage) {
        let photo = CapturedPhoto(image: image, uploadState: .uploading)
        let id = photo.id
        withAnimation(.easeOut(duration: 0.15)) { photos.append(photo) }
        guard let occurrenceId = task.occurrenceId, let data = PhotoCompression.compress(image) else {
            // No occurrence to attach evidence to (shouldn't normally
            // happen — every synced task has one) or compression failed:
            // keep the photo visible locally rather than losing it, just
            // without a real upload behind it.
            if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].uploadState = .failed }
            return
        }
        Task {
            do {
                let result = try await APIClient.shared.createSubmission(occurrenceId: occurrenceId, kind: "photo", contentType: "image/jpeg")
                if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].submissionId = result.submissionId }
                try await APIClient.shared.uploadToPresignedURL(result.uploadURL, data: data, contentType: "image/jpeg")
                try await APIClient.shared.completeSubmission(id: result.submissionId)
                if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].uploadState = .uploaded }
            } catch {
                if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].uploadState = .failed }
            }
        }
    }

    /// A reopened task has nothing captured locally any more — load the
    /// real photos the backend actually has instead of showing nothing (or,
    /// before this existed, a fake placeholder keyed only by a count).
    private func loadExistingSubmissions(occurrenceId: String) async {
        guard photos.isEmpty, task.submittedPhotoCount > 0 || task.done else { return }
        guard let subs = try? await APIClient.shared.fetchSubmissions(occurrenceId: occurrenceId), !subs.isEmpty else { return }
        photos = subs.filter { $0.kind == "photo" }.map {
            CapturedPhoto(downloadURL: $0.downloadUrl, submissionId: $0.id, uploadState: $0.status == "uploaded" ? .uploaded : .uploading)
        }
    }

    // Purple "asked to skip" pending state — mirrors the green "submitted"
    // card above (same shape/frame language) but a distinct color so a kid
    // scanning back in can tell at a glance which kind of "waiting" this is.
    private var bypassSentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask sent 🙋").font(Typography.display(21, weight: .heavy)).foregroundStyle(KidTheme.ink)
                Text("Waiting for a parent to say yes or no. You'll get a little ping when they do.")
                    .font(Typography.font(14.5, weight: .regular)).foregroundStyle(KidTheme.inkSoft)
                HStack(spacing: 10) {
                    ProgressView().tint(KidTheme.lavenderText)
                    Text("Sent just now").font(Typography.font(13.5, weight: .bold)).foregroundStyle(KidTheme.lavenderText)
                }
                .padding(12)
                .background(.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 6)
            }
            .padding(22)
            .background(KidTheme.lavender)
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(KidTheme.ink, lineWidth: 2.5))
            .clipShape(RoundedRectangle(cornerRadius: 20))

            Button {
                dismiss()
            } label: {
                Text("Back to today")
                    .font(Typography.font(18, weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.line, lineWidth: 2))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct IdentifiedInt: Identifiable { var value: Int; var id: Int { value } }

/// A real captured/loaded photo, not a decorative placeholder — a local
/// UIImage if it was just taken this session, else the backend's own copy
/// via its presigned download URL (a reopened task after relaunch has no
/// local image left). Falls back to a plain loading tile, never a fake
/// "photo" standing in for one that doesn't exist yet.
private struct SubmittedPhotoThumbnail: View {
    var photo: CapturedPhoto

    var body: some View {
        Group {
            if let image = photo.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let urlString = photo.downloadURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else if phase.error != nil {
                        loadingPlaceholder(failed: true)
                    } else {
                        loadingPlaceholder(failed: false)
                    }
                }
            } else {
                loadingPlaceholder(failed: photo.uploadState == .failed)
            }
        }
        .clipped()
    }

    private func loadingPlaceholder(failed: Bool) -> some View {
        ZStack {
            KidTheme.cream
            if failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: "EA580C"))
            } else {
                ProgressView().tint(KidTheme.greenDeep)
            }
        }
    }
}

// Full-screen swipe-through viewer for a kid's own already-submitted
// photos — real images (see SubmittedPhotoThumbnail), not a decorative
// mock. Fully interactive swipe-to-dismiss (no scrollable content here to
// compete with), plus the same X for a kid who doesn't think to swipe.
private struct KidPhotoViewer: View {
    var photos: [CapturedPhoto]
    @State var index: Int
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    SubmittedPhotoThumbnail(photo: photo)
                        .aspectRatio(3.0/4.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(28)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Text("Swipe down to close")
                    .font(Typography.font(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 14)
            }
        }
        .swipeToDismiss(interactive: true, onClose)
    }
}

// One captured photo in the multi-photo grid, with an upload-state badge
// (uploading spinner / failed retry) over the real image.
private struct KidCapturedPhotoTile: View {
    var photo: CapturedPhoto
    var onRetake: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SubmittedPhotoThumbnail(photo: photo)
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if photo.uploadState == .uploading {
                ProgressView()
                    .tint(.white)
                    .padding(6)
                    .background(Circle().fill(KidTheme.ink.opacity(0.6)))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            Button(action: onRetake) {
                Image(systemName: photo.uploadState == .failed ? "exclamationmark.arrow.circlepath" : "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(photo.uploadState == .failed ? Color(hex: "EA580C") : KidTheme.ink.opacity(0.8)))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }
}

// "Can't do this today?" compose step — an optional reason, matching the
// parent-side review card's expectation that a bypass request explains
// itself (see ScreenProfile's bypass row / TaskReviewCard's note block).
private struct BypassRequestSheet: View {
    var taskTitle: String
    var onSend: (String, Bool) -> Void
    var onCancel: () -> Void

    @State private var reason = ""
    @State private var hasVoiceNote = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    // Same either/or rule as the parent-side Redo compose sheet: a typed
    // reason or a recorded one, not necessarily both.
    private var canSend: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasVoiceNote }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: kid.of(16, 22)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask to skip this one?")
                        .font(Typography.display(kid.of(20, 26), weight: .heavy)).foregroundStyle(KidTheme.ink)
                    Text(taskTitle)
                        .font(Typography.font(kid.of(14, 16), weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                }

                TextField("e.g. I have soccer practice today", text: $reason, axis: .vertical)
                    .font(Typography.font(kid.of(15, 17), weight: .regular))
                    .lineLimit(3...5)
                    .padding(kid.of(14, 18))
                    .background(KidTheme.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                KidVoiceRecorderButton(hasVoiceNote: $hasVoiceNote)

                if !kid.isRegular { Spacer(minLength: 0) }

                Button { onSend(reason.trimmingCharacters(in: .whitespacesAndNewlines), hasVoiceNote) } label: {
                    Text("Send to a parent")
                        .font(Typography.display(kid.of(18, 21), weight: .heavy))
                        .foregroundStyle(canSend ? .white : Color(hex: "B5C8BC"))
                        .frame(maxWidth: .infinity)
                        .frame(height: kid.of(58, 66))
                        .background(
                            // Offset duplicate behind the face, not
                            // `.shadow()` — that ghosts the label text too.
                            // Dropped (not just faded) while disabled, along
                            // with the fill swap below — fading both
                            // overlapping layers together via `.opacity()`
                            // (the old approach) exposed the seam between
                            // them as a smeared double edge instead of
                            // reading as one grayed-out button.
                            ZStack {
                                if canSend {
                                    RoundedRectangle(cornerRadius: 20).fill(Color(hex: "5B3FA6")).offset(y: 5)
                                }
                                RoundedRectangle(cornerRadius: 20).fill(canSend ? KidTheme.lavenderText : KidTheme.line)
                            }
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(kid.of(20, 32))
            .kidContentColumn(kid.isRegular ? 620 : nil)
            .frame(maxHeight: .infinity, alignment: kid.isRegular ? .center : .top)
            .background(KidTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
            }
        }
        .swipeToDismiss(interactive: false, onCancel)
    }
}

// Idle → recording (live timer + pulsing dot) → recorded (duration, tap to
// remove) — shared between the bypass compose sheet above and the normal
// task-submission note field, which used to have no voice option at all.
private struct KidVoiceRecorderButton: View {
    @Binding var hasVoiceNote: Bool

    private enum VoiceState { case idle, recording, recorded }
    @State private var voiceState: VoiceState = .idle
    @State private var recordSeconds = 0
    @State private var recordingTask: Task<Void, Never>?
    @State private var dotPulse = false

    private var recordedTimeLabel: String { String(format: "%d:%02d", recordSeconds / 60, recordSeconds % 60) }

    private func startRecording() {
        recordSeconds = 0
        voiceState = .recording
        recordingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                recordSeconds += 1
            }
        }
    }

    private func stopRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceState = .recorded
        hasVoiceNote = true
    }

    private func removeRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceState = .idle
        recordSeconds = 0
        hasVoiceNote = false
    }

    var body: some View {
        Button {
            switch voiceState {
            case .idle: startRecording()
            case .recording: stopRecording()
            case .recorded: removeRecording()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(voiceState == .idle ? KidTheme.lavender : KidTheme.lavenderText)
                    switch voiceState {
                    case .idle:
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(KidTheme.lavenderText)
                    case .recording:
                        Circle().fill(.white).frame(width: 12, height: 12).opacity(dotPulse ? 1 : 0.35)
                    case .recorded:
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    switch voiceState {
                    case .idle:
                        Text("Record a voice note")
                            .font(Typography.font(14, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Text("Say it instead of typing it")
                            .font(Typography.font(12, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                    case .recording:
                        Text("Recording… \(recordedTimeLabel)")
                            .font(Typography.font(14, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Text("Tap to stop")
                            .font(Typography.font(12, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                    case .recorded:
                        Text("Voice note attached · \(recordedTimeLabel)")
                            .font(Typography.font(14, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        Text("Tap to remove")
                            .font(Typography.font(12, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(voiceState == .recording ? KidTheme.lavenderText : KidTheme.line, lineWidth: voiceState == .recording ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // Deferred into .task rather than started directly from the state
        // change, for the same reason the splash screen's pulse is
        // deferred (see RootView.SplashScreenView) — a repeatForever
        // kicked off at the same moment the view reappears can lose the
        // race with SwiftUI's own initial transaction and never actually
        // start.
        .task(id: voiceState) {
            guard voiceState == .recording else { dotPulse = false; return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, voiceState == .recording else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dotPulse = true }
        }
        .onDisappear {
            recordingTask?.cancel()
            recordingTask = nil
        }
    }
}
