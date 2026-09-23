import SwiftUI
import UIKit
import AVFoundation

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
    // The real on-disk cache backing this photo's upload — see capture()/
    // upload(). Lets the upload survive the app being killed/backgrounded
    // mid-flight (the pending write in LocalStore points at this same
    // file) instead of only ever existing as an in-memory UIImage.
    var pendingWriteId: String?

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
    // The recorded file for a fresh recording made this session — nil
    // otherwise. hasVoiceNote below also counts a voice note the backend
    // already has (task.submissionHasVoiceNote, from a reopened task with
    // nothing local left to hold), so it stays true across relaunch even
    // though this URL itself doesn't persist.
    @State private var voiceNoteURL: URL?
    @State private var voiceUploadState: CapturedPhoto.UploadState = .idle
    private var hasVoiceNote: Bool { voiceNoteURL != nil || task.submissionHasVoiceNote }
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
    @State private var courseAssignment: ApiCourseAssignment?
    @State private var courseFullyDone = false
    // Drives the note field's tap-to-dismiss below — see the guarded
    // simultaneousGesture on the ScrollView's content for why this exists
    // instead of the blanket dismissKeyboardOnTap() this screen used to
    // have (removed for fighting the field's own tap-to-focus).
    @FocusState private var noteFocused: Bool
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
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if bypassSent {
                            bypassSentCard
                        } else if let assignment = courseAssignment, !submitted {
                            // A special task is finished by finishing its
                            // course, so the camera/voice flow doesn't apply
                            // — this is the first submission kind that
                            // genuinely branches (photo and voice are both
                            // offered unconditionally today).
                            courseTaskContent(assignment)
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
                // A blanket dismissKeyboardOnTap() used to sit on this whole
                // screen and got removed for fighting the field's own tap-
                // to-focus (see RootView's own usage for the same fight) —
                // it fired unconditionally on *any* tap, including the one
                // trying to open the keyboard in the first place. This is
                // the same idea but guarded: it only ever acts when the
                // field is *already* focused, so it can only ever take
                // focus away, never race a tap that's trying to give it
                // focus. Kept alongside scrollDismissesKeyboard below (drag-
                // to-dismiss), not instead of it.
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if noteFocused { noteFocused = false }
                    }
                )
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
            await reloadCourseAssignment()
            guard let occurrenceId = task.occurrenceId else { return }
            await loadExistingSubmissions(occurrenceId: occurrenceId)
            resumePendingUploads()
        }
        .onChange(of: voiceNoteURL) { _, newValue in
            if let newValue { uploadVoiceNote(fileURL: newValue) }
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
                occurrenceId: task.occurrenceId,
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

    /// A special task: watch the course, answer its quizzes, hand in. The
    /// backend refuses the submission until the course is actually finished,
    /// so the button here matches that rather than letting them tap it and
    /// get an error.
    @ViewBuilder private func courseTaskContent(_ assignment: ApiCourseAssignment) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if bonusMinutesForTask > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(KidTheme.greenDeep)
                    Text("Finish this to earn \(bonusMinutesForTask) more minutes")
                        .font(Typography.font(15, weight: .bold))
                        .foregroundStyle(KidTheme.ink)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KidTheme.greenTint))
            }

            CourseFlowView(assignment: assignment) {
                await reloadCourseAssignment()
            }

            Button {
                justSubmitted = true
                submitted = true
            } label: {
                Text("All done!")
                    .font(Typography.display(18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(courseFullyDone ? KidTheme.greenDeep : KidTheme.mutedBorder))
            }
            .buttonStyle(.plain)
            .disabled(!courseFullyDone)
        }
        .padding(.top, 12)
    }

    private var bonusMinutesForTask: Int {
        guard let childId = SessionManager.shared.activeChildId else { return 0 }
        return LocalStore.shared.cachedTasks(childId: childId)
            .first { $0.id == task.id }?.bonusMinutes ?? 0
    }

    private func reloadCourseAssignment() async {
        guard let childId = SessionManager.shared.activeChildId,
              let assignmentId = LocalStore.shared.cachedTasks(childId: childId)
                  .first(where: { $0.id == task.id })?.courseAssignmentId
        else { return }
        guard let refreshed = try? await APIClient.shared.fetchCourseAssignments(childId: childId)
            .first(where: { $0.id == assignmentId }) else { return }
        courseAssignment = refreshed
        courseFullyDone = !refreshed.progress.isEmpty
            && refreshed.progress.allSatisfy { $0.status == "completed" }
    }

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
        Text(photos.isEmpty ? "Add a photo if you'd like" : "Add another photo, or you're all set")
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
            .focused($noteFocused)

        KidVoiceRecorderButton(voiceNoteURL: $voiceNoteURL)
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

        // A photo that didn't make it up (a network blip, or the server
        // wasn't configured yet — see PhotoCompression/capture(_:)) used to
        // be a dead end once "All done!" moved past the capture screen:
        // there was no way back to the retake button that lived there. This
        // retries the same photo already sitting on the device — no need to
        // take it again, and no need to leave this screen.
        if hasFailedUploads {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(hex: "EA580C"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("A photo didn't send").font(Typography.font(13.5, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    Text("Check your connection, then try again").font(Typography.font(12, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                }
                Spacer(minLength: 8)
                Button("Retry") { retryFailedUploads() }
                    .font(Typography.font(13.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(hex: "EA580C"))
                    .clipShape(Capsule())
            }
            .padding(14)
            .background(Color(hex: "FFEDD5"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.top, 14)
        }

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
            if voiceUploadState == .failed, let url = voiceNoteURL {
                HStack(spacing: 8) {
                    Label("Voice note didn't send", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.font(13.5, weight: .bold))
                        .foregroundStyle(Color(hex: "EA580C"))
                    Spacer(minLength: 8)
                    Button("Retry") { uploadVoiceNote(fileURL: url) }
                        .font(Typography.font(13, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(hex: "EA580C"))
                        .clipShape(Capsule())
                }
                .padding(.top, 10)
            } else {
                Label(voiceUploadState == .uploading ? "Sending voice note…" : "Voice note attached", systemImage: "waveform")
                    .font(Typography.font(13.5, weight: .bold))
                    .foregroundStyle(KidTheme.lavenderText)
                    .padding(.top, 10)
            }
        }

        // A parent asking for a redo (task.redoRequested) already reopens
        // straight into the edit flow, so this is for everything else a
        // kid might want to fix on their own before a parent has looked at
        // it — a photo they want to swap, one more thing to add, a typo in
        // the note. Gone once it's actually approved: that submission is
        // done, not something to reopen and rewrite after the fact.
        if !task.approved {
            Button { submitted = false } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                    Text("Redo this")
                        .font(Typography.font(15, weight: .bold))
                }
                .foregroundStyle(KidTheme.greenDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(KidTheme.cream)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.line, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
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

    private var hasFailedUploads: Bool { photos.contains { $0.uploadState == .failed } }

    private func capture(_ image: UIImage) {
        let photo = CapturedPhoto(image: image, uploadState: .uploading)
        withAnimation(.easeOut(duration: 0.15)) { photos.append(photo) }
        upload(photoId: photo.id, image: image)
    }

    /// Retries every failed photo using the image already on the device —
    /// there's no reason to make a kid retake a perfectly good photo just
    /// because the upload itself (a network blip, or the server not being
    /// configured yet) is what actually failed.
    private func retryFailedUploads() {
        for photo in photos where photo.uploadState == .failed {
            guard let image = photo.image else { continue }
            if let i = photos.firstIndex(where: { $0.id == photo.id }) { photos[i].uploadState = .uploading }
            upload(photoId: photo.id, image: image)
        }
    }

    /// Standard practice for a mobile upload, not just an in-memory
    /// attempt: the compressed file is written to disk immediately — real
    /// local caching, not just a UIImage that's gone the moment this view
    /// (or the app) closes — and tracked as a real PendingWrite in
    /// LocalStore. If the app is killed or backgrounded mid-upload, the
    /// file and the queue entry both survive; resumePendingUploads() (see
    /// .task below) picks it back up on next launch without the kid ever
    /// needing to retake anything. The queue entry is only removed once
    /// the real upload actually finishes.
    private func upload(photoId: UUID, image: UIImage) {
        guard let occurrenceId = task.occurrenceId, let childId = SessionManager.shared.activeChildId else {
            // No occurrence to attach evidence to — shouldn't normally
            // happen (every synced task has one) — keep the photo visible
            // locally rather than losing it, just without a real upload
            // behind it.
            if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].uploadState = .failed }
            return
        }
        Task { @MainActor in
            // The JPEG re-encode is real CPU work and used to run right
            // here, synchronously, before this Task even started — which
            // blocked the screen for its duration on every single photo,
            // and visibly worse capturing several in a row, since each one
            // froze the UI before the next could even show. Detached so it
            // runs on a background thread instead; everything after this
            // await stays on the main actor same as before, so the @State
            // mutations below are still safe.
            guard let data = await Task.detached(priority: .userInitiated, operation: {
                PhotoCompression.compress(image)
            }).value else {
                if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].uploadState = .failed }
                return
            }
            guard let fileURL = LocalStore.cacheFile(data: data, suffix: "jpg") else {
                if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].uploadState = .failed }
                return
            }
            // A retry re-compresses and re-caches fresh, so the previous
            // attempt's queue entry (and its now-redundant file) would
            // otherwise just sit there orphaned forever.
            if let previousId = photos.first(where: { $0.id == photoId })?.pendingWriteId,
               let stale = LocalStore.shared.pendingWrites(childId: childId).first(where: { $0.id == previousId }) {
                if let path = stale.localFilePath { try? FileManager.default.removeItem(atPath: path) }
                LocalStore.shared.removePendingWrite(stale)
            }
            let write = PendingWrite(childId: childId, kind: "uploadPhoto", occurrenceId: occurrenceId,
                                      localFilePath: fileURL.path, contentType: "image/jpeg")
            LocalStore.shared.queueWrite(write)
            if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].pendingWriteId = write.id }

            do {
                let result = try await APIClient.shared.createSubmission(occurrenceId: occurrenceId, kind: "photo", contentType: "image/jpeg")
                if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].submissionId = result.submissionId }
                try await APIClient.shared.uploadToPresignedURL(result.uploadURL, data: data, contentType: "image/jpeg")
                try await APIClient.shared.completeSubmission(id: result.submissionId)
                if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].uploadState = .uploaded }
                LocalStore.shared.removePendingWrite(write)
                try? FileManager.default.removeItem(at: fileURL)
            } catch {
                // Left queued on purpose — this is exactly what
                // resumePendingUploads() retries later, whether that's a
                // manual tap on the (now-visible, since this is a real
                // failure) retry icon, or automatically next launch.
                if let i = photos.firstIndex(where: { $0.id == photoId }) { photos[i].uploadState = .failed }
            }
        }
    }

    /// Picks up any photo upload that was still queued from a previous
    /// session for this exact task — the app got backgrounded/killed
    /// before it finished, but the file (and the queue entry pointing at
    /// it) survived on disk. Runs once per appearance; a write that's
    /// already represented in `photos` (this same session) is skipped.
    private func resumePendingUploads() {
        guard let occurrenceId = task.occurrenceId, let childId = SessionManager.shared.activeChildId else { return }
        let known = Set(photos.compactMap(\.pendingWriteId))
        for write in LocalStore.shared.pendingWrites(childId: childId)
        where write.kind == "uploadPhoto" && write.occurrenceId == occurrenceId && !known.contains(write.id) {
            guard let path = write.localFilePath, let image = UIImage(contentsOfFile: path) else {
                // The file's gone (e.g. iOS reclaimed Caches under storage
                // pressure) — nothing left to retry from; drop the
                // now-meaningless queue entry rather than leave it stuck.
                LocalStore.shared.removePendingWrite(write)
                continue
            }
            var photo = CapturedPhoto(image: image, uploadState: .uploading)
            photo.pendingWriteId = write.id
            photos.append(photo)
            upload(photoId: photo.id, image: image)
        }
    }

    /// Same eager-upload-on-capture shape as a photo — the moment
    /// KidVoiceRecorderButton hands back a real recorded file, it goes
    /// straight up, not deferred until "All done!". Previously nothing
    /// played this role at all: hasVoiceNote was a Bool a kid could set to
    /// true with zero bytes ever leaving the device.
    private func uploadVoiceNote(fileURL: URL) {
        guard let occurrenceId = task.occurrenceId else {
            voiceUploadState = .failed
            return
        }
        voiceUploadState = .uploading
        Task { @MainActor in
            guard let data = await Task.detached(priority: .userInitiated, operation: {
                try? Data(contentsOf: fileURL)
            }).value else {
                voiceUploadState = .failed
                return
            }
            do {
                let result = try await APIClient.shared.createSubmission(occurrenceId: occurrenceId, kind: "voice", contentType: "audio/m4a")
                try await APIClient.shared.uploadToPresignedURL(result.uploadURL, data: data, contentType: "audio/m4a")
                try await APIClient.shared.completeSubmission(id: result.submissionId)
                voiceUploadState = .uploaded
            } catch {
                voiceUploadState = .failed
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
    // .fill (crop to tile, tidy grid look) for the grid; .fit (whole photo,
    // no cropping) for the full-screen viewer — cropping there was cutting
    // off real parts of a kid's own evidence photo just to force it into a
    // fixed 3:4 box.
    var contentMode: ContentMode = .fill

    @State private var remoteImage: UIImage?
    @State private var remoteFailed = false
    // Bumped to force a fresh load on manual retry — .task(id:) only
    // re-fires when its id actually changes.
    @State private var retryToken = 0

    var body: some View {
        Group {
            if let image = photo.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let urlString = photo.downloadURL {
                if let remoteImage {
                    Image(uiImage: remoteImage).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    Button {
                        guard remoteFailed else { return }
                        retryToken += 1
                    } label: {
                        loadingPlaceholder(failed: remoteFailed)
                    }
                    .buttonStyle(.plain)
                    .disabled(!remoteFailed)
                    // Grid tile and full-screen viewer both read this same
                    // photo.downloadURL — cached here for the same reason
                    // as the parent-side RemotePhoto, so opening the
                    // viewer doesn't re-download what the grid tile just
                    // showed a moment earlier. ImageCache.load also
                    // dedupes an in-flight fetch for the same URL instead
                    // of the tile and the viewer each firing their own —
                    // both are alive at once, since a fullScreenCover
                    // doesn't tear down what's presenting it.
                    .task(id: "\(urlString)#\(retryToken)") {
                        remoteFailed = false
                        guard let url = URL(string: urlString) else { remoteFailed = true; return }
                        remoteImage = await ImageCache.shared.load(url)
                        remoteFailed = remoteImage == nil
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
// mock. Rebuilt on the same ScrollView-paging + pinch-zoom pattern as the
// parent-side PhotoGalleryViewer (TaskReviewDeck.swift), not TabView(.page)
// — pinch-to-zoom needs a plain DragGesture for panning while zoomed, which
// would otherwise fight TabView(.page)'s own paging gesture. Photos show
// uncropped here (.fit) even though the grid crops them to fill a tidy
// tile (.fill) — forcing every photo into a fixed 3:4 box here was cutting
// real content off a kid's own evidence photo just to fit the frame.
private struct KidPhotoViewer: View {
    var photos: [CapturedPhoto]
    @State var index: Int
    var onClose: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var scrollPosition: Int?
    @State private var isZoomed = false

    private var count: Int { photos.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                        KidZoomablePhotoPage(photo: photo, isZoomed: $isZoomed)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition)
            .scrollDisabled(isZoomed)
            .scrollIndicators(.hidden)
            .onAppear { scrollPosition = index }
            .onChange(of: scrollPosition) { _, newValue in
                guard let newValue, newValue != index else { return }
                index = newValue
                isZoomed = false
            }

            VStack {
                HStack {
                    if count > 1 {
                        Text("\(index + 1) of \(count)")
                            .font(Typography.font(13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                Spacer()
                if !isZoomed {
                    Text("Swipe down to close")
                        .font(Typography.font(12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 14)
                }
            }
        }
        .offset(y: dragOffset)
        // Only mostly-vertical, and only while not zoomed — panning a
        // zoomed photo shouldn't also drag the whole viewer down, and this
        // never competes with the pager's own horizontal swipe.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard !isZoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    guard !isZoomed else { return }
                    if value.translation.height > 90, abs(value.translation.height) > abs(value.translation.width) {
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                    }
                }
        )
    }
}

// Pinch (or double-tap) to zoom, drag to pan while zoomed — mirrors
// TaskReviewDeck's own ZoomablePhotoPage. Attached with .simultaneousGesture
// so, at 1x, this never competes with the pager's own swipe recognition.
private struct KidZoomablePhotoPage: View {
    var photo: CapturedPhoto
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 4

    private func resetZoom() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        isZoomed = false
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(maxScale, max(1, lastScale * value.magnification))
                isZoomed = scale > 1.01
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { withAnimation(.easeOut(duration: 0.2)) { resetZoom() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    var body: some View {
        let photoView = SubmittedPhotoThumbnail(photo: photo, contentMode: .fit)
            .padding(.horizontal, 12)
            .scaleEffect(scale)
            .offset(offset)

        Group {
            if isZoomed {
                photoView.simultaneousGesture(magnify.simultaneously(with: pan))
            } else {
                photoView.simultaneousGesture(magnify)
            }
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.25)) {
                if scale > 1 {
                    resetZoom()
                } else {
                    scale = 2.5; lastScale = 2.5; isZoomed = true
                }
            }
        }
    }
}

// One captured photo in the multi-photo grid, with an upload-state badge
// (progress ring wrapped around the tile / failed retry) over the real image.
private struct KidCapturedPhotoTile: View {
    var photo: CapturedPhoto
    var onRetake: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SubmittedPhotoThumbnail(photo: photo)
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            // No visible "uploading" state at all any more — not even the
            // wrap-around ring this used to show. A kid taking a photo
            // should see it looking simply *done* immediately (upload is
            // a background concern, especially once local caching means
            // nothing's actually at risk of being lost — see capture()),
            // not a circular-arrow icon sitting on top of a still-settling
            // photo reading as "something's stuck." A retake button only
            // shows once there's a real reason for one: the photo's fully
            // up (they might still want a redo) or the upload genuinely
            // failed (an actionable problem, not a wait).
            if photo.uploadState == .uploaded || photo.uploadState == .failed {
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
}

// PhotoUploadRing (a wrap-around loading arc) used to live here — removed
// by direct request: even a real, well-designed progress indicator still
// reads as "something's pending/stuck" to a kid glancing at their own
// photo. See KidCapturedPhotoTile's own comment for what replaced it
// (nothing — the photo just looks done immediately).

// "Can't do this today?" compose step — an optional reason, matching the
// parent-side review card's expectation that a bypass request explains
// itself (see ScreenProfile's bypass row / TaskReviewCard's note block).
private struct BypassRequestSheet: View {
    var taskTitle: String
    // Needed to actually upload a recorded voice note as a real submission
    // (same createSubmission/uploadToPresignedURL/completeSubmission
    // pipeline a photo uses) — nil only in the "no occurrence yet" edge
    // case TaskDetailView's own photo upload already guards against.
    var occurrenceId: String?
    var onSend: (String, Bool) -> Void
    var onCancel: () -> Void

    @State private var reason = ""
    @State private var voiceNoteURL: URL?
    @State private var voiceUploadState: CapturedPhoto.UploadState = .idle
    private var hasVoiceNote: Bool { voiceNoteURL != nil }
    @FocusState private var reasonFocused: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    // Same either/or rule as the parent-side Redo compose sheet: a typed
    // reason or a recorded one, not necessarily both.
    private var canSend: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasVoiceNote }

    private func uploadVoiceNote(fileURL: URL) {
        guard let occurrenceId else {
            voiceUploadState = .failed
            return
        }
        voiceUploadState = .uploading
        Task { @MainActor in
            guard let data = await Task.detached(priority: .userInitiated, operation: {
                try? Data(contentsOf: fileURL)
            }).value else {
                voiceUploadState = .failed
                return
            }
            do {
                let result = try await APIClient.shared.createSubmission(occurrenceId: occurrenceId, kind: "voice", contentType: "audio/m4a")
                try await APIClient.shared.uploadToPresignedURL(result.uploadURL, data: data, contentType: "audio/m4a")
                try await APIClient.shared.completeSubmission(id: result.submissionId)
                voiceUploadState = .uploaded
            } catch {
                voiceUploadState = .failed
            }
        }
    }

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
                    .focused($reasonFocused)

                KidVoiceRecorderButton(voiceNoteURL: $voiceNoteURL)

                if voiceUploadState == .failed, let url = voiceNoteURL {
                    HStack(spacing: 8) {
                        Label("Voice note didn't send", systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.font(13, weight: .bold))
                            .foregroundStyle(Color(hex: "EA580C"))
                        Spacer(minLength: 8)
                        Button("Retry") { uploadVoiceNote(fileURL: url) }
                            .font(Typography.font(12.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(hex: "EA580C"))
                            .clipShape(Capsule())
                    }
                }

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
            // Guarded the same way as TaskDetailView's own note field
            // above: only acts when the field is already focused, so it
            // can only take focus away, never race the tap that's trying
            // to give it focus. This screen isn't a ScrollView, so there's
            // no drag-to-dismiss fallback the way the scroll one has —
            // this is the only dismiss path here.
            .simultaneousGesture(
                TapGesture().onEnded {
                    if reasonFocused { reasonFocused = false }
                }
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
            }
        }
        .onChange(of: voiceNoteURL) { _, newValue in
            if let newValue { uploadVoiceNote(fileURL: newValue) }
        }
        .swipeToDismiss(interactive: false, onCancel)
    }
}

// Idle → recording (live timer + pulsing dot) → recorded (duration, tap to
// remove) — shared between the bypass compose sheet above and the normal
// task-submission note field. Used to be a plain Task.sleep timer with no
// AVAudioRecorder behind it at all — "recording" was a Bool a kid could
// flip to true, with no actual audio ever captured, which is exactly why a
// "voice note" never really went anywhere: there was nothing to upload.
private struct KidVoiceRecorderButton: View {
    // The real recorded file on disk once stopped — nil the rest of the
    // time. The caller (TaskDetailView/BypassRequestSheet) owns uploading
    // it; this view only owns capturing it.
    @Binding var voiceNoteURL: URL?

    private enum VoiceState { case idle, recording, recorded }
    @State private var voiceState: VoiceState = .idle
    @State private var recordSeconds = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var dotPulse = false
    @State private var recorder: AVAudioRecorder?

    private var recordedTimeLabel: String { String(format: "%d:%02d", recordSeconds / 60, recordSeconds % 60) }

    // The completion-handler form of this call (requestRecordPermission
    // { granted in ... }) is what triggered "unsafeForcedSync called from
    // Swift Concurrent context" — AVFoundation's own bridge from its
    // async-native implementation back to that legacy callback shape is
    // what does the unsafe synchronous wait, not anything in this file.
    // The async entry point goes straight to the real implementation
    // instead of through that shim. Task inherits this button action's
    // MainActor context, so beginRecording()'s own synchronous
    // AVAudioSession calls still land on the main actor, same as before.
    private func startRecording() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return }
            beginRecording()
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        guard (try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker])) != nil,
              (try? session.setActive(true)) != nil else { return }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: fileURL, settings: settings) else { return }
        recorder = r
        r.record()
        recordSeconds = 0
        voiceState = .recording
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                recordSeconds += 1
            }
        }
    }

    private func stopRecording() {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        voiceNoteURL = recorder?.url
        recorder = nil
        voiceState = .recorded
    }

    private func removeRecording() {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        if let url = voiceNoteURL { try? FileManager.default.removeItem(at: url) }
        voiceNoteURL = nil
        voiceState = .idle
        recordSeconds = 0
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
            timerTask?.cancel()
            timerTask = nil
            recorder?.stop()
            recorder = nil
        }
    }
}
