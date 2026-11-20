import SwiftUI
import UIKit

private let taskDetailBottomAnchorID = "task-detail-bottom-anchor"

/// One photo a kid has captured for this task. `image` is set the moment
/// it's taken (so the tile shows something real immediately, not a
/// placeholder); `downloadURL` is set instead when this photo came from
/// reopening an already-submitted task (the backend's copy — there's no
/// local UIImage left once the app has relaunched). `photoId` is the
/// photo's own id, the server's submission id too: Send names it, and
/// PhotoUploads carries its upload (`uploadState` follows it there).
private struct CapturedPhoto: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage?
    var downloadURL: String?
    var photoId: String?
    var uploadState: UploadState = .idle

    enum UploadState: Equatable { case idle, uploading, uploaded, failed }

    static func == (l: CapturedPhoto, r: CapturedPhoto) -> Bool { l.id == r.id }
}

struct TaskDetailView: View {
    let task: KidTask
    /// The kid's Send: queues it and returns the outbox write's id, which
    /// this screen waits on (nil when there's nothing to send it to).
    var onComplete: (_ photoCount: Int, _ note: String?, _ photoIds: [String]) -> String?
    var onRequestBypass: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [CapturedPhoto] = []
    @State private var showCamera = false
    @State private var note = ""
    @State private var submitted: Bool
    // Distinguishes "just tapped All done! this session" (a brief fresh-
    // confirmation beat) from "reopened an already-done task" (goes
    // straight to the plain recap) — both share the same photo grid/note
    // below, only the header card differs. Neither one tells the kid their
    // evidence is still pending review — that's the parent's business, not
    // something to make the kid sit and wonder about.
    @State private var justSubmitted = false
    // Haptics at the kid's own tap, the moment it's sent: success for a
    // task sent in, a soft tap for asking to skip.
    @State private var sentTick = 0
    @State private var skipSentTick = 0
    // Send waits for the server's yes (photos checked in R2) before
    // "Good Job!": a moment on a good connection. Offline, or past
    // `sendWait`, it's saved and says so; refused, it says that.
    @State private var sending = false
    @State private var savedOffline = false
    @State private var sendFailed = false
    private static let sendWait: Double = 8
    @State private var showBypassSheet = false
    @State private var bypassSent = false
    @State private var viewerIndex: Int?
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
    init(task: KidTask, onComplete: @escaping (_ photoCount: Int, _ note: String?, _ photoIds: [String]) -> String?,
         onRequestBypass: @escaping (String) -> Void = { _ in }) {
        self.task = task
        self.onComplete = onComplete
        self.onRequestBypass = onRequestBypass
        _submitted = State(initialValue: task.done)
        _note = State(initialValue: task.submissionNote ?? "")
    }

    var body: some View {
        GeometryReader { geo in
        let wide = kid.isRegular && geo.size.width > geo.size.height
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if bypassSent {
                            bypassSentCard
                        } else if !submitted {
                            VStack(alignment: .leading, spacing: 0) { notYetSubmittedContent(wide: wide) }
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -20))))
                        } else {
                            VStack(alignment: .leading, spacing: 0) { submittedContent(height: geo.size.height) }
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)), removal: .opacity))
                        }

                        // Nothing sits below "Add a note" but the (short) rest
                        // of the form, so the keyboard alone can cover it —
                        // scrolling to this anchor on keyboard-open brings the
                        // note field and "All done!" back into view instead of
                        // leaving them hidden behind it.
                        Color.clear.frame(height: 1).id(taskDetailBottomAnchorID)
                    }
                    .padding(wide ? 32 : 20)
                    .kidContentColumn(wide && !submitted && !bypassSent ? nil : kid.contentMaxWidth)
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
            .background(EPaperBackground())
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
            if DemoMode.kidHandIn, !submitted {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                handIn()
            }
            guard let occurrenceId = task.occurrenceId else { return }
            await loadExistingSubmissions(occurrenceId: occurrenceId)
            showQueuedPhotos(occurrenceId: occurrenceId)
        }
        // A photo's upload is PhotoUploads' (it outlives this screen); its
        // state shows here, a failed one with its retry.
        .onChange(of: PhotoUploads.shared.states) { _, states in
            for i in photos.indices {
                guard let id = photos[i].photoId, let state = states[id] else { continue }
                switch state {
                case .uploading: photos[i].uploadState = .uploading
                case .uploaded: photos[i].uploadState = .uploaded
                case .failed: photos[i].uploadState = .failed
                }
            }
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
                onSend: { reason in
                    skipSentTick += 1
                    showBypassSheet = false
                    bypassSent = true
                    onRequestBypass(reason)
                },
                onCancel: { showBypassSheet = false }
            )
        }
        // Felt the instant the kid sends it, not when the tick has finished
        // popping in.
        .sensoryFeedback(.success, trigger: sentTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: skipSentTick)
        }
    }

    // MARK: - Not-yet-submitted flow (capture + note + "All done!")

    /// Hands the task in the moment the kid says they're done.
    ///
    /// The submit used to ride on the button out of this screen, so the other two ways out
    /// of this screen — the Back button and a swipe down — closed it after
    /// it had already said "submitted", and nothing ever reached the server:
    /// the task sat at pending and the parent saw "waiting". Called again
    /// after "Redo this", which is a real resubmission.
    ///
    /// Confirmed by the server, not assumed (2026-11-19): Send names the
    /// photos, waits in the outbox until they're uploaded, and the server
    /// counts each only once R2 has it. "Good Job!" waits for that yes,
    /// usually under a second, since photos start uploading the moment
    /// they're taken. Offline, or still going after `sendWait`, it's saved
    /// on the device and goes by itself; the kid is told so.
    private func handIn() {
        guard !sending else { return }
        noteFocused = false
        sendFailed = false
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let photoIds = photos.compactMap(\.photoId)
        sending = true
        Task {
            await PhotoUploads.shared.ready(photoIds)
            let writeId = onComplete(photos.count, trimmed.isEmpty ? nil : trimmed, photoIds)
            let arrival: Outbox.Arrival
            if DemoMode.isBuild || writeId == nil {
                arrival = .sent
            } else if !ConnectionStatus.shared.isOnline {
                arrival = .notYet
            } else {
                arrival = await Outbox.waitUntilSent(writeId!, seconds: Self.sendWait)
            }
            sending = false
            switch arrival {
            case .sent:
                sentTick += 1
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    submitted = true
                    justSubmitted = true
                }
            case .notYet:
                skipSentTick += 1
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    savedOffline = true
                    submitted = true
                }
            case .refused:
                withAnimation(.easeOut(duration: 0.2)) { sendFailed = true }
            }
        }
    }

    // Wide (an iPad sideways): the task, the note and the buttons on the
    // left, the photos on the right, so the whole screen is used and
    // nothing needs scrolling. Upright: one column, top to bottom.
    @ViewBuilder private func notYetSubmittedContent(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    taskHeader
                    noteAndActions(wide: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    photoArea(wide: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            taskHeader
            photoArea(wide: false)
            noteAndActions(wide: false)
        }
    }

    @ViewBuilder private var taskHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(task.title)
                .font(Typography.display(28, weight: .heavy))
                .foregroundStyle(KidTheme.ink)
            Spacer()
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "FFEDD5"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.top, 16)
        }

    }

    @ViewBuilder private func photoArea(wide: Bool) -> some View {
        if photos.isEmpty {
            Button { showCamera = true } label: {
                VStack(spacing: 16) {
                    Circle().fill(KidTheme.paperButton).frame(width: 84, height: 84)
                        .overlay(Image(systemName: "camera.fill").font(.system(size: 36, weight: .bold)).foregroundStyle(.white))
                    Text("Tap to take a photo").font(Typography.display(20, weight: .bold))
                    Text("Show us what you did").font(Typography.font(14, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                }
                .frame(maxWidth: .infinity)
                .frame(height: wide ? 440 : 280)
                .background(KidTheme.cream)
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(KidTheme.line, style: StrokeStyle(lineWidth: 2.5, dash: [7])))
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .padding(.top, wide ? 0 : 24)
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
                        if let photoId = photo.photoId, photo.downloadURL == nil { PhotoUploads.shared.discard(photoId) }
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
            .padding(.top, wide ? 0 : 24)
        }

    }

    @ViewBuilder private func noteAndActions(wide: Bool) -> some View {
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

        // Elevated "kid" pill per the style guide: mascot green face, a
        // solid green-deep base for the 3D lift — a duplicate offset
        // rectangle behind the face, not a `.shadow()` (which would also
        // shadow the label text itself, ghosting a second copy of it
        // below). A photo is always optional (2026-11-05): "All done!" is
        // always there.
        Button { handIn() } label: {
            HStack(spacing: 10) {
                if sending {
                    ProgressView().tint(KidTheme.paperInk)
                    Text("Sending…")
                } else {
                    Text("All done!")
                }
            }
            .font(KidTheme.buttonFont(20))
            .foregroundStyle(KidTheme.paperInk)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        // Its own success haptic plays once the server has it (sentTick),
        // so no press tap.
        .buttonStyle(KidRaisedButtonStyle.paper(tapHaptic: false))
        .disabled(sending)
        .padding(.top, photos.isEmpty ? 18 : 22)

        if sendFailed {
            Text("That didn't send. Try again.")
                .font(Typography.font(14, weight: .bold))
                .foregroundStyle(Color(hex: "EA580C"))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }

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

    // Centred on the screen. Right after "All done!": the party popper
    // bursts, "Congrats!", keep it up. Reopened while it waits: the
    // hourglass and "Task is pending approval". Approved: the confetti,
    // already burst, and a green Approved.
    @ViewBuilder private func submittedContent(height: CGFloat) -> some View {
        VStack(spacing: 22) {
            if (justSubmitted || task.approved) && !savedOffline {
                PartyPopperBurst(plays: justSubmitted)
                    .frame(width: kid.of(260, 320), height: kid.of(260, 320))
                    .accessibilityHidden(true)
            } else {
                PendingHourglass()
                    .frame(width: kid.of(220, 270), height: kid.of(220, 270))
                    .accessibilityHidden(true)
            }
            if task.approved {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(Typography.display(kid.of(20, 24), weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: kid.of(54, 62))
                    .background(Capsule().fill(KidTheme.green))
            } else if savedOffline {
                VStack(spacing: 8) {
                    Text("Saved!")
                        .font(Typography.display(kid.of(32, 38), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text("It'll send when you're back online.")
                        .font(Typography.font(kid.of(18, 21), weight: .bold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                .multilineTextAlignment(.center)
            } else if justSubmitted {
                VStack(spacing: 8) {
                    Text("Good Job! 🎉")
                        .font(Typography.display(kid.of(32, 38), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text("Keep up the great work!")
                        .font(Typography.font(kid.of(18, 21), weight: .bold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                .multilineTextAlignment(.center)
            } else {
                Text("Task is pending approval")
                    .font(Typography.display(kid.of(22, 28), weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: height * 0.62)

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

        // A parent asking for a redo (task.redoRequested) already reopens
        // straight into the edit flow, so this is for everything else a
        // kid might want to fix on their own before a parent has looked at
        // it — a photo they want to swap, one more thing to add, a typo in
        // the note. Gone once it's actually approved: that submission is
        // done, not something to reopen and rewrite after the fact.
        if !task.approved {
            Button { withAnimation(.easeInOut(duration: 0.25)) { submitted = false } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                    Text("Redo this")
                        .font(Typography.font(15, weight: .bold))
                }
                .foregroundStyle(KidTheme.greenDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(KidTheme.cream)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.line, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.top, 36)
        }

    }

    // MARK: - Real capture + upload

    private var hasFailedUploads: Bool { photos.contains { $0.uploadState == .failed } }

    /// The upload starts the moment the photo is taken (PhotoUploads), so
    /// it's usually up before the kid presses Send.
    private func capture(_ image: UIImage) {
        var photo = CapturedPhoto(image: image, uploadState: .uploading)
        if let occurrenceId = task.occurrenceId, let childId = SessionManager.shared.activeChildId {
            photo.photoId = PhotoUploads.shared.add(image, occurrenceId: occurrenceId, taskId: task.id, childId: childId)
        } else {
            // Nothing to attach it to (shouldn't happen: every synced task
            // has an occurrence): shown, marked as not sent.
            photo.uploadState = .failed
        }
        withAnimation(.easeOut(duration: 0.15)) { photos.append(photo) }
    }

    /// Tries every photo that didn't go, from the files already saved on
    /// the device: no retaking a good photo because the network failed.
    private func retryFailedUploads() {
        PhotoUploads.shared.retryNow()
    }

    /// Photos taken for this task that haven't gone yet (the app was
    /// closed, or there was no connection): shown again, still on their
    /// way.
    private func showQueuedPhotos(occurrenceId: String) {
        let shown = Set(photos.compactMap(\.photoId))
        for write in LocalStore.shared.uploadWrites()
        where write.occurrenceId == occurrenceId && !shown.contains(write.photoId ?? "") {
            guard let path = write.localFilePath, let image = UIImage(contentsOfFile: path) else { continue }
            let state = write.photoId.flatMap { PhotoUploads.shared.state(of: $0) }
            photos.append(CapturedPhoto(image: image, photoId: write.photoId,
                                        uploadState: state == .failed ? .failed : (write.uploadedAt == nil ? .uploading : .uploaded)))
        }
    }

    /// A reopened task has nothing captured locally any more — load the
    /// real photos the backend actually has instead of showing nothing (or,
    /// before this existed, a fake placeholder keyed only by a count).
    private func loadExistingSubmissions(occurrenceId: String) async {
        guard photos.isEmpty, task.submittedPhotoCount > 0 || task.done else { return }
        guard let subs = try? await APIClient.shared.fetchSubmissions(occurrenceId: occurrenceId), !subs.isEmpty else { return }
        // Only photos R2 has: one still on its way from this device shows
        // from its saved file instead (showQueuedPhotos).
        photos = subs.filter { $0.kind == "photo" && $0.status == "uploaded" }.map {
            CapturedPhoto(downloadURL: $0.downloadUrl, photoId: $0.id, uploadState: $0.status == "uploaded" ? .uploaded : .uploading)
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
    var onSend: (String) -> Void
    var onCancel: () -> Void

    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    // A reason is what a parent decides on, so there's nothing to send
    // without one.
    private var canSend: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: kid.of(16, 22)) {
                // A plain x, not the toolbar's Cancel: iOS draws that as a
                // frosted glass pill with a soft shadow, which read as blurry.
                SheetCloseButton(label: "Cancel", action: onCancel)
                    .padding(.leading, -6)
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

                if !kid.isRegular { Spacer(minLength: 0) }

                Button { onSend(reason.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                    Text("Send")
                        .font(Typography.display(kid.of(18, 21), weight: .heavy))
                        .foregroundStyle(canSend ? .white : Color(hex: "B5C8BC"))
                        .frame(maxWidth: .infinity)
                        .frame(height: kid.of(58, 66))
                }
                // A deep purple, so the white label is crisp: on the light
                // lavender it had too little contrast and its edges smeared.
                .buttonStyle(KidRaisedButtonStyle(face: Color(hex: "5B3FA6"), base: Color(hex: "3F2A7A")))
                .disabled(!canSend)
            }
            .padding(kid.of(20, 32))
            .kidContentColumn(kid.isRegular ? 620 : nil)
            .frame(maxHeight: .infinity, alignment: kid.isRegular ? .center : .top)
            .background(EPaperBackground())
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
            .toolbar(.hidden, for: .navigationBar)
        }
        .swipeToDismiss(interactive: false, onCancel)
    }
}


/// The kid's big raised buttons: a coloured face on a darker base, like a
/// key. Pressed, the face sinks onto the base (no shrinking, so the base
/// never shows as a shadow) with a light tap, the cheapest haptic there is.
/// Disabled: flat and grey. The label sets its own size and text colour.
extension KidRaisedButtonStyle {
    /// The kid's e-paper button (2026-11-09, the user's call): pale sage
    /// paper, a fine edge, a soft paper base; its words are
    /// `KidTheme.paperInk`. Warm and easy on the eyes, nothing glaring.
    static func paper(tapHaptic: Bool = true) -> KidRaisedButtonStyle {
        KidRaisedButtonStyle(face: KidTheme.paperButton, base: KidTheme.paperButtonBase,
                             edge: KidTheme.paperButtonEdge, depth: 4, tapHaptic: tapHaptic)
    }
}

struct KidRaisedButtonStyle: ButtonStyle {
    var face: Color
    var base: Color
    /// A fine edge round the face (the e-paper button's).
    var edge: Color? = nil
    var disabledFace: Color = KidTheme.line
    var cornerRadius: CGFloat = 20
    var depth: CGFloat = 5
    /// Off where the tap already has its own haptic (a success, say).
    var tapHaptic = true

    func makeBody(configuration: Configuration) -> some View {
        Raised(configuration: configuration, style: self)
    }

    private struct Raised: View {
        let configuration: Configuration
        let style: KidRaisedButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            // Flat, 2D (2026-11-15, the user's call): the face alone, no
            // raised base under it (`base` and `depth` are kept, unused); a
            // press dims and shrinks it a touch.
            configuration.label
                .background(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(isEnabled ? style.face : style.disabledFace))
                .opacity(pressed ? 0.85 : 1)
                .scaleEffect(pressed ? 0.98 : 1)
            .animation(.spring(duration: 0.12, bounce: 0), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in style.tapHaptic && now }
        }
    }
}

// MARK: - The party popper

/// A party popper going off: the cone kicks in, then confetti and three
/// streamers burst out of its mouth and the confetti settles a little.
/// Drawn on a 200-point square. `plays: false` (or Reduce Motion) shows it
/// already burst, still.
private struct PartyPopperBurst: View {
    var plays: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cone = false
    @State private var burst: CGFloat = 0
    @State private var float = false
    // A soft tap the moment it goes off (the user asked for the burst to be
    // felt), after the success tap of "All done!" itself.
    @State private var popTick = 0

    private static let mouth = CGPoint(x: 98, y: 112)
    private static let colors = ["3FCE64", "B9F04F", "FFC93C", "FF6B9A", "4D9CFF", "A86BFF", "FF8A3D"].map { Color(hex: $0) }
    /// Each piece: direction (degrees), distance, spin, colour, kind
    /// (0 strip, 1 dot, 2 squiggle). Fixed, so it bursts the same way each time.
    private static let pieces: [(angle: Double, distance: CGFloat, spin: Double, color: Int, kind: Int)] = [
        (-117, 52, 71, 0, 0), (-113, 51, 72, 1, 1), (-102, 83, 138, 2, 2), (-102, 72, 50, 3, 0), (-98, 53, 39, 4, 1),
        (-87, 85, 145, 5, 2), (-83, 57, 56, 6, 0), (-79, 80, 154, 0, 1), (-72, 52, 109, 1, 2), (-69, 70, 32, 2, 0),
        (-65, 52, 168, 3, 1), (-57, 72, 54, 4, 2), (-52, 73, 159, 5, 0), (-47, 70, 75, 6, 1), (-44, 67, 29, 0, 2),
        (-42, 84, 8, 1, 0), (-39, 76, 50, 2, 1), (-30, 69, 62, 3, 2), (-21, 57, 74, 4, 0), (-22, 76, 50, 5, 1),
        (-16, 81, 58, 6, 2), (-10, 88, 18, 0, 0), (-9, 58, 138, 1, 1), (1, 58, 60, 2, 2), (2, 68, 8, 3, 0), (12, 87, 172, 4, 1),
    ]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack(alignment: .topLeading) {
                streamers(s)
                confetti(s)
                    .offset(y: float ? 4 * s : 0)
                popper(s)
            }
            .frame(width: 200 * s, height: 200 * s, alignment: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: play)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: popTick)
    }

    private func play() {
        guard plays, !reduceMotion else {
            cone = true; burst = 1
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { popTick += 1 }
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { cone = true }
        withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.3)) { burst = 1 }
        // One slow settle, not an endless float: a looping animation keeps
        // the screen redrawing (about a tenth of the CPU) for as long as
        // it's open.
        withAnimation(.easeInOut(duration: 1.6).delay(1.1)) { float = true }
    }

    private func streamers(_ s: CGFloat) -> some View {
        let m = Self.mouth
        let paths: [(Color, [CGPoint])] = [
            (Self.colors[3], [CGPoint(x: 120, y: 70), CGPoint(x: 150, y: 92), CGPoint(x: 160, y: 60)]),
            (Self.colors[4], [CGPoint(x: 80, y: 70), CGPoint(x: 110, y: 50), CGPoint(x: 96, y: 22)]),
            (Self.colors[0], [CGPoint(x: 140, y: 110), CGPoint(x: 150, y: 140), CGPoint(x: 184, y: 128)]),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<paths.count, id: \.self) { i in
                let pts = paths[i].1
                Path { p in
                    p.move(to: CGPoint(x: m.x * s, y: m.y * s))
                    p.addCurve(to: CGPoint(x: pts[2].x * s, y: pts[2].y * s),
                               control1: CGPoint(x: pts[0].x * s, y: pts[0].y * s),
                               control2: CGPoint(x: pts[1].x * s, y: pts[1].y * s))
                }
                .trim(from: 0, to: burst)
                .stroke(paths[i].0, style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
            }
        }
    }

    private func confetti(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Self.pieces.count, id: \.self) { i in
                let piece = Self.pieces[i]
                let rad = piece.angle * .pi / 180
                let x = Self.mouth.x + CGFloat(cos(rad)) * piece.distance * burst
                let y = Self.mouth.y + CGFloat(sin(rad)) * piece.distance * burst
                confettiPiece(piece.kind, Self.colors[piece.color], s)
                    .rotationEffect(.degrees(piece.spin * Double(burst) + 180 * Double(burst)))
                    .position(x: x * s, y: y * s)
                    .opacity(burst > 0.05 ? 1 : 0)
            }
        }
        .frame(width: 200 * s, height: 200 * s)
    }

    @ViewBuilder private func confettiPiece(_ kind: Int, _ color: Color, _ s: CGFloat) -> some View {
        switch kind {
        case 0:
            RoundedRectangle(cornerRadius: 1.5 * s).fill(color).frame(width: 10 * s, height: 5 * s)
        case 1:
            Circle().fill(color).frame(width: 7.2 * s, height: 7.2 * s)
        default:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 3 * s))
                p.addQuadCurve(to: CGPoint(x: 6 * s, y: 3 * s), control: CGPoint(x: 3 * s, y: -2 * s))
                p.addQuadCurve(to: CGPoint(x: 12 * s, y: 3 * s), control: CGPoint(x: 9 * s, y: 8 * s))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
            .frame(width: 12 * s, height: 6 * s)
        }
    }

    // The cone, pointing down and left, with pale stripes and a darker
    // rim at its mouth. It kicks back a little as it goes off.
    private func popper(_ s: CGFloat) -> some View {
        let cone = Path { p in
            p.move(to: CGPoint(x: 38 * s, y: 178 * s))
            p.addLine(to: CGPoint(x: 72 * s, y: 98 * s))
            p.addLine(to: CGPoint(x: 118 * s, y: 144 * s))
            p.closeSubpath()
        }
        return ZStack(alignment: .topLeading) {
            cone.fill(LinearGradient(colors: [Color(hex: "FF8A3D"), Color(hex: "FFC93C")],
                                     startPoint: .bottomLeading, endPoint: .topTrailing))
            Path { p in
                for (a, b) in [((40, 140), (90, 190)), ((52, 116), (110, 174)), ((64, 92), (130, 158))] {
                    p.move(to: CGPoint(x: CGFloat(a.0) * s, y: CGFloat(a.1) * s))
                    p.addLine(to: CGPoint(x: CGFloat(b.0) * s, y: CGFloat(b.1) * s))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 7 * s)
            .clipShape(cone)
            Ellipse()
                .fill(Color(hex: "E2701F"))
                .frame(width: 66 * s, height: 18 * s)
                .rotationEffect(.degrees(45))
                .position(x: 95 * s, y: 121 * s)
        }
        .frame(width: 200 * s, height: 200 * s, alignment: .topLeading)
        .scaleEffect(self.cone ? 1 : 0.5, anchor: UnitPoint(x: 0.4, y: 0.7))
        .rotationEffect(.degrees(self.cone ? 0 : -20), anchor: UnitPoint(x: 0.2, y: 0.9))
        .opacity(self.cone ? 1 : 0)
    }
}

// MARK: - The hourglass

/// A task sent in and still waiting for a parent: an hourglass flips over
/// and its sand runs down once, then rests. Drawn on a 200-point square.
/// Plays once, not in a loop (a looping animation keeps the screen
/// redrawing); Reduce Motion shows it at rest.
private struct PendingHourglass: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flipped = false
    @State private var sand: CGFloat = 0

    private let frameColor = Color(hex: "25924A")
    private let glass = Color(hex: "E4F8E9")
    private let sandColor = Color(hex: "FFB938")

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack(alignment: .topLeading) {
                bulb(top: true, s).fill(glass)
                bulb(top: false, s).fill(glass)
                // Sand: the top bulb's empties from the top down, the
                // bottom one's fills from the bottom up.
                bulb(top: true, s).fill(sandColor)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: (100 - 50 - 34 * sand) * s).offset(y: (50 + 34 * sand) * s)
                    }
                bulb(top: false, s).fill(sandColor)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: 40 * sand * s).offset(y: (160 - 40 * sand) * s)
                    }
                Rectangle().fill(sandColor)
                    .frame(width: 3 * s, height: max(0, (160 - 40 * sand - 100)) * s)
                    .offset(x: 98.5 * s, y: 100 * s)
                    .opacity(sand > 0.02 && sand < 0.98 ? 1 : 0)
                bulb(top: true, s).stroke(frameColor.opacity(0.35), lineWidth: 3 * s)
                bulb(top: false, s).stroke(frameColor.opacity(0.35), lineWidth: 3 * s)
                RoundedRectangle(cornerRadius: 6 * s).fill(frameColor)
                    .frame(width: 112 * s, height: 14 * s).offset(x: 44 * s, y: 26 * s)
                RoundedRectangle(cornerRadius: 6 * s).fill(frameColor)
                    .frame(width: 112 * s, height: 14 * s).offset(x: 44 * s, y: 160 * s)
            }
            .frame(width: 200 * s, height: 200 * s, alignment: .topLeading)
            .rotationEffect(.degrees(flipped ? 0 : -180))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            guard !reduceMotion else { flipped = true; sand = 0.7; return }
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) { flipped = true }
            withAnimation(.easeInOut(duration: 2.4).delay(0.55)) { sand = 0.7 }
        }
    }

    private func bulb(top: Bool, _ s: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (top ? y : 200 - y) * s) }
        var path = Path()
        path.move(to: p(60, 40))
        path.addLine(to: p(140, 40))
        path.addCurve(to: p(104, 100), control1: p(140, 76), control2: p(108, 86))
        path.addLine(to: p(96, 100))
        path.addCurve(to: p(60, 40), control1: p(92, 86), control2: p(60, 76))
        path.closeSubpath()
        return path
    }
}
