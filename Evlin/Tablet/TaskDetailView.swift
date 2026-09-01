import SwiftUI

struct TaskDetailView: View {
    let task: KidTask
    var onComplete: () -> Void
    var onRequestBypass: (String, Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var showComic = false
    @State private var captured = false
    @State private var submitted = false
    @State private var showBypassSheet = false
    @State private var bypassSent = false

    private var panels: [ComicPanel] { TabletData.comicPanels(for: task.iconTaskId) }

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

                        Text("Take a photo to show you're done")
                            .font(Typography.display(18, weight: .bold))
                            .foregroundStyle(KidTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32).padding(.bottom, 16)

                        Button { captured = true } label: {
                            VStack(spacing: 16) {
                                Circle().fill(KidTheme.green).frame(width: 84, height: 84)
                                    .overlay(Image(systemName: captured ? "checkmark" : "camera.fill").font(.system(size: 36, weight: .bold)).foregroundStyle(.white))
                                Text(captured ? "Got it!" : "Tap to take a photo").font(Typography.display(20, weight: .bold))
                                Text(captured ? "Tap to try again" : "Show us what you did").font(Typography.font(14, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .background(captured ? KidTheme.greenTint : KidTheme.cream)
                            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(captured ? KidTheme.green : KidTheme.line, style: StrokeStyle(lineWidth: 2.5, dash: captured ? [] : [7])))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                        .buttonStyle(.plain)

                        // Elevated "kid" pill per the style guide: mascot green face,
                        // a solid green-deep base for the 3D lift — a duplicate
                        // offset rectangle behind the face, not a `.shadow()`
                        // (which would also shadow the label text itself,
                        // ghosting a second copy of it below).
                        Button { if captured { submitted = true } } label: {
                            Text("All done!")
                                .font(Typography.display(20, weight: .heavy))
                                .foregroundStyle(captured ? .white : Color(hex: "B5C8BC"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .background(
                                    ZStack {
                                        if captured {
                                            RoundedRectangle(cornerRadius: 20).fill(KidTheme.greenDeep).offset(y: 5)
                                        }
                                        RoundedRectangle(cornerRadius: 20).fill(captured ? KidTheme.green : KidTheme.line)
                                    }
                                    // Flattened into one layer first so any
                                    // future press/disabled dimming can't
                                    // split the two rectangles apart into a
                                    // smeared double edge.
                                    .compositingGroup()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!captured)
                        .padding(.top, 18)
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

                        Button {
                            onComplete()
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
                        .padding(.top, 16)
                    }
                }
                .padding(20)
            }
            .background(KidTheme.background)
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

// "Can't do this today?" compose step — an optional reason, matching the
// parent-side review card's expectation that a bypass request explains
// itself (see ScreenProfile's bypass row / TaskReviewCard's note block).
private struct BypassRequestSheet: View {
    var taskTitle: String
    var onSend: (String, Bool) -> Void
    var onCancel: () -> Void

    @State private var reason = ""
    @State private var voiceRecorded = false

    // Same either/or rule as the parent-side Redo compose sheet: a typed
    // reason or a recorded one, not necessarily both.
    private var canSend: Bool { !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceRecorded }

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
                    voiceRecorded.toggle()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(voiceRecorded ? KidTheme.lavenderText : KidTheme.lavender)
                            Image(systemName: voiceRecorded ? "checkmark" : "mic.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(voiceRecorded ? .white : KidTheme.lavenderText)
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(voiceRecorded ? "Voice note attached" : "Record a voice note")
                                .font(Typography.font(14, weight: .heavy)).foregroundStyle(KidTheme.ink)
                            Text(voiceRecorded ? "Tap to remove" : "Say it instead of typing it")
                                .font(Typography.font(12, weight: .medium)).foregroundStyle(KidTheme.inkSoft)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KidTheme.line))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button { onSend(reason.trimmingCharacters(in: .whitespacesAndNewlines), voiceRecorded) } label: {
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
