import SwiftUI

struct TaskDetailView: View {
    let task: KidTask
    var onComplete: (_ photoCount: Int, _ note: String?) -> Void
    var onRequestBypass: (String, Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var showComic = false
    // Several photos, not one — mirrors the parent side's multi-page
    // submissions (e.g. Math Practice's photoCount 3 in TaskStore). Each
    // entry is a stable id so a single photo can be retaken/removed without
    // disturbing the others.
    @State private var photos: [UUID] = []
    @State private var note = ""
    @State private var submitted: Bool
    // Distinguishes "just tapped All done! this session" (shows the
    // "waiting for approval" beat) from "reopened an already-done task"
    // (shows a plain recap instead) — both share the same photo grid/note
    // below, only the header card differs.
    @State private var justSubmitted = false
    @State private var showBypassSheet = false
    @State private var bypassSent = false
    @State private var viewerIndex: Int?

    private var panels: [ComicPanel] { TabletData.comicPanels(for: task.iconTaskId) }

    // Seeds submitted/photos/note from the task itself — without this, a
    // kid reopening an already-done task would land back on the "take a
    // photo" capture flow instead of seeing what they actually turned in,
    // since photos/note otherwise start empty every time this view is
    // freshly created.
    init(task: KidTask, onComplete: @escaping (_ photoCount: Int, _ note: String?) -> Void, onRequestBypass: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.task = task
        self.onComplete = onComplete
        self.onRequestBypass = onRequestBypass
        _submitted = State(initialValue: task.done)
        _photos = State(initialValue: (0..<task.submittedPhotoCount).map { _ in UUID() })
        _note = State(initialValue: task.submissionNote ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if bypassSent {
                        bypassSentCard
                    } else if !submitted {
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

                        if !panels.isEmpty {
                            Button { showComic = true } label: {
                                HStack(spacing: 12) {
                                    HStack(spacing: 3) {
                                        ForEach(panels.prefix(3)) { p in
                                            Image(p.imageName).resizable().aspectRatio(contentMode: .fill)
                                                .frame(width: 36, height: 46).clipShape(RoundedRectangle(cornerRadius: 7))
                                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(KidTheme.ink, lineWidth: 1.5))
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Watch Evlin show you").font(Typography.font(15.5, weight: .heavy)).foregroundStyle(KidTheme.greenDeep)
                                        Text("Tap to see how").font(Typography.font(12.5, weight: .semibold)).foregroundStyle(KidTheme.greenDeep)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(KidTheme.green)
                                }
                                .padding(14)
                                .background(KidTheme.cream)
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 18)
                        }

                        Text(photos.isEmpty ? "Take a photo to show you're done" : "Add another photo, or you're all set")
                            .font(Typography.display(18, weight: .bold))
                            .foregroundStyle(KidTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32).padding(.bottom, 16)

                        if photos.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.15)) { photos.append(UUID()) } } label: {
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
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(Array(photos.enumerated()), id: \.element) { index, id in
                                    KidCapturedPhotoTile(pageNumber: index + 1) {
                                        // A retake removes and expects the kid
                                        // to tap "Add another photo" again,
                                        // rather than silently swapping the
                                        // same mock image back in — makes the
                                        // retry an explicit, visible action.
                                        withAnimation(.easeOut(duration: 0.15)) { photos.removeAll { $0 == id } }
                                    }
                                }
                                Button { withAnimation(.easeOut(duration: 0.15)) { photos.append(UUID()) } } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(KidTheme.green)
                                        Text("Add photo")
                                            .font(Typography.font(11.5, weight: .bold))
                                            .foregroundStyle(KidTheme.inkSoft)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(3.0/4.0, contentMode: .fit)
                                    .background(KidTheme.cream)
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KidTheme.line, style: StrokeStyle(lineWidth: 2, dash: [6])))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
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

                        // Elevated "kid" pill per the style guide: mascot green face,
                        // a solid green-deep base for the 3D lift — a duplicate
                        // offset rectangle behind the face, not a `.shadow()`
                        // (which would also shadow the label text itself,
                        // ghosting a second copy of it below).
                        Button { if !photos.isEmpty { submitted = true; justSubmitted = true } } label: {
                            Text("All done!")
                                .font(Typography.display(20, weight: .heavy))
                                .foregroundStyle(!photos.isEmpty ? .white : Color(hex: "B5C8BC"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .background(
                                    ZStack {
                                        if !photos.isEmpty {
                                            RoundedRectangle(cornerRadius: 20).fill(KidTheme.greenDeep).offset(y: 5)
                                        }
                                        RoundedRectangle(cornerRadius: 20).fill(!photos.isEmpty ? KidTheme.green : KidTheme.line)
                                    }
                                    // Flattened into one layer first so any
                                    // future press/disabled dimming can't
                                    // split the two rectangles apart into a
                                    // smeared double edge.
                                    .compositingGroup()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(photos.isEmpty)
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
                    } else {
                        if justSubmitted {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Evidence submitted 🎉").font(Typography.display(21, weight: .heavy)).foregroundStyle(KidTheme.ink)
                                Text("Waiting for a parent to approve. You'll get a little ping when they do.")
                                    .font(Typography.font(14.5, weight: .regular)).foregroundStyle(KidTheme.inkSoft)
                                HStack(spacing: 10) {
                                    ProgressView().tint(KidTheme.greenDeep)
                                    Text("Sent just now").font(Typography.font(13.5, weight: .bold)).foregroundStyle(KidTheme.greenDeep)
                                }
                                .padding(12)
                                .background(.white.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .padding(.top, 12)
                            }
                            .padding(22)
                            .background(KidTheme.cream)
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else if task.pendingApproval && !task.approved {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Waiting for your parent ⏳").font(Typography.display(21, weight: .heavy)).foregroundStyle(KidTheme.ink)
                                Text("Here's what you turned in — they haven't checked it yet.")
                                    .font(Typography.font(14.5, weight: .regular)).foregroundStyle(KidTheme.inkSoft)
                            }
                            .padding(22)
                            .background(Color(hex: "FFF3E0"))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("All done! ✅").font(Typography.display(21, weight: .heavy)).foregroundStyle(KidTheme.ink)
                                Text("Here's what you turned in for this one.")
                                    .font(Typography.font(14.5, weight: .regular)).foregroundStyle(KidTheme.inkSoft)
                            }
                            .padding(22)
                            .background(KidTheme.cream)
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        }

                        if !photos.isEmpty {
                            Text("Your photo\(photos.count == 1 ? "" : "s")")
                                .font(Typography.display(16, weight: .bold))
                                .foregroundStyle(KidTheme.ink)
                                .padding(.top, 20).padding(.bottom, 10)

                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(Array(photos.enumerated()), id: \.element) { index, _ in
                                    Button { viewerIndex = index } label: {
                                        MockHomeworkPhoto(pageNumber: index + 1)
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

                        Button {
                            if justSubmitted { onComplete(photos.count, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note) }
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
                }
                .padding(20)
            }
            .background(KidTheme.background)
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                        .foregroundStyle(KidTheme.greenDeep)
                }
            }
        }
        .fullScreenCover(isPresented: $showComic) {
            ComicViewerView(title: task.title, panels: panels)
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { IdentifiedInt(value: $0) } },
            set: { viewerIndex = $0?.value }
        )) { wrapped in
            KidPhotoViewer(count: photos.count, index: wrapped.value) { viewerIndex = nil }
        }
        .sheet(isPresented: $showBypassSheet) {
            BypassRequestSheet(
                taskTitle: task.title,
                onSend: { reason, hasVoice in
                    showBypassSheet = false
                    bypassSent = true
                    onRequestBypass(reason, hasVoice)
                },
                onCancel: { showBypassSheet = false }
            )
            .presentationDetents([.medium])
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

// Full-screen swipe-through viewer for a kid's own already-submitted
// photos — plain TabView(.page) is fine here (no nested scroll/drag inside
// each page to fight with, unlike the parent side's zoomable gallery), so
// there's no need for that view's hand-built pager.
private struct KidPhotoViewer: View {
    var count: Int
    @State var index: Int
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(0..<count, id: \.self) { i in
                    MockHomeworkPhoto(pageNumber: i + 1, detailed: true)
                        .padding(28)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: count > 1 ? .always : .never))

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}

// One captured photo in the multi-photo grid — reuses the parent side's
// mock "photographed page" (MockHomeworkPhoto) so a submission looks
// identical from either side, with a retake button standing in for a kid
// pointing the camera again at a photo that came out blurry/wrong.
private struct KidCapturedPhotoTile: View {
    var pageNumber: Int
    var onRetake: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MockHomeworkPhoto(pageNumber: pageNumber)
                .aspectRatio(3.0/4.0, contentMode: .fit)

            Button(action: onRetake) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(KidTheme.ink.opacity(0.8)))
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
    private enum VoiceState { case idle, recording, recorded }
    @State private var voiceState: VoiceState = .idle
    @State private var recordSeconds = 0
    @State private var recordingTask: Task<Void, Never>?
    @State private var dotPulse = false

    // Same either/or rule as the parent-side Redo compose sheet: a typed
    // reason or a recorded one, not necessarily both.
    private var canSend: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceState == .recorded }

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
    }

    private func removeRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceState = .idle
        recordSeconds = 0
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask to skip this one?")
                        .font(Typography.display(20, weight: .heavy)).foregroundStyle(KidTheme.ink)
                    Text(taskTitle)
                        .font(Typography.font(14, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                }

                TextField("e.g. I have soccer practice today", text: $reason, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .lineLimit(3...5)
                    .padding(14)
                    .background(KidTheme.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

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
                // Deferred into .task rather than started directly from the
                // state change, for the same reason the splash screen's
                // pulse is deferred (see RootView.SplashScreenView) — a
                // repeatForever kicked off at the same moment the view
                // reappears can lose the race with SwiftUI's own initial
                // transaction and never actually start.
                .task(id: voiceState) {
                    guard voiceState == .recording else { dotPulse = false; return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled, voiceState == .recording else { return }
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dotPulse = true }
                }

                Spacer(minLength: 0)

                Button { onSend(reason.trimmingCharacters(in: .whitespacesAndNewlines), voiceState == .recorded) } label: {
                    Text("Send to a parent")
                        .font(Typography.display(18, weight: .heavy))
                        .foregroundStyle(canSend ? .white : Color(hex: "B5C8BC"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
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
            .padding(20)
            .background(KidTheme.background)
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
            }
        }
    }
}
