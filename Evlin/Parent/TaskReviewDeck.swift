import SwiftUI

// Tinder-style task review — opened when a parent taps a task row. A
// submitted task (task.state == .review — the kid has actually turned
// something in, so there's a real decision to make) is a draggable card:
// swipe right to approve, left to ask for a redo, with the same live
// tilt/stamp feedback Tinder gives while dragging. Every other state
// (nothing submitted yet, already resolved, a bypass request) shows the
// same card without the gesture — there's no decision a drag could
// represent for those, so it's buttons only, same as before.
// A Redo always pauses on a small compose step first so the parent can send
// the kid a quick note or voice message about what to fix — swiping left
// past the threshold opens that same compose step rather than skipping it.
struct TaskReviewDeckView: View {
    @Binding var tasks: [ChildTask]
    var childName: String
    // Only used to unlock the phone once every task this deck knows about
    // is resolved (see approve() below) — ScreenProfile's own "Approve All"
    // button already does this in one shot, but approving one at a time
    // through this deck used to leave the child stuck on .lockedTasks even
    // after every task was actually done, since nothing here ever touched
    // Child.status. Optional because a couple of call sites review a
    // same-day subset of events rather than a specific child's full task
    // list — auto-unlock only makes sense when there's a real Child to
    // unlock and this deck can see everything relevant to that decision.
    var childId: String? = nil
    var startIndex: Int
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var showRedoCompose = false
    @State private var editingTask: ChildTask?
    // The current card's live drag position — reset to .zero every time
    // the card underneath it changes (advance()), or the next card would
    // render already offset from whatever the previous one ended up at.
    @State private var dragOffset: CGSize = .zero
    private let swipeThreshold: CGFloat = 120

    init(tasks: Binding<[ChildTask]>, childName: String, childId: String? = nil, startIndex: Int, onDismiss: @escaping () -> Void) {
        self._tasks = tasks
        self.childName = childName
        self.childId = childId
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _index = State(initialValue: startIndex)
    }

    private var currentTask: ChildTask? { tasks.indices.contains(index) ? tasks[index] : nil }

    // Mirrors the branching the old single-task TaskDetailSheet had:
    // .review/.bypass have a real "send it back" action (Redo / Deny —
    // both just move the task to .pending). .pending/.overdue only have a
    // one-way "mark complete". .done can still be sent back to redo even
    // after approval — parents change their mind — so it keeps a Redo
    // option too, with "Next task" standing in for "Approve" since it's
    // already approved. .bypassed is the only truly final state, with no
    // action buttons besides Next.
    private func primaryLabel(for task: ChildTask) -> String {
        switch task.state {
        case .bypass: return "Allow bypass"
        case .done: return "Next task"
        default: return "Approve"
        }
    }
    private func secondaryLabel(for task: ChildTask) -> String? {
        switch task.state {
        case .review, .done: return "Redo"
        case .bypass: return "Deny"
        default: return nil
        }
    }
    private func canRedo(_ task: ChildTask) -> Bool { task.state == .review || task.state == .bypass || task.state == .done }
    private func isResolved(_ task: ChildTask) -> Bool { task.state == .bypassed }

    var body: some View {
        NavigationStack {
            ZStack {
                EColor.surface.ignoresSafeArea()

                if let task = currentTask {
                    VStack(spacing: 18) {
                        cardStack(for: task)
                        actionButtons(for: task)
                    }
                    // Horizontal margin wider than the card's own 24pt
                    // corner radius — at the old uniform 20pt, the margin
                    // was *tighter* than the curve, so each rounded corner
                    // read as cramped right up against the screen's square
                    // edge instead of floating clear of it.
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                } else {
                    doneState
                }
            }
            .navigationTitle(childName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss(); onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let task = currentTask {
                        Button { editingTask = task } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(EColor.onSurface)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showRedoCompose) {
            if let task = currentTask {
                RedoComposeSheet(childName: childName, taskTitle: task.title, actionLabel: secondaryLabel(for: task) ?? "Redo", onSend: { note, hasVoice in
                    applyRedo(note: note, hasVoice: hasVoice)
                    showRedoCompose = false
                    // Finish the fly-off-left the swipe started, then bring
                    // in the next card fresh (no leftover offset).
                    withAnimation(.easeIn(duration: 0.18)) { dragOffset = CGSize(width: -520, height: dragOffset.height) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        dragOffset = .zero
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { advance() }
                    }
                }, onCancel: {
                    showRedoCompose = false
                    // A swipe-initiated redo leans the card out before this
                    // sheet appears (see the drag gesture) — cancelling
                    // means the decision didn't happen, so it springs back.
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { dragOffset = .zero }
                })
                .interactiveDismissDisabled()
                .presentationDetents([.large])
            }
        }
        .sheet(item: $editingTask) { task in
            EditTaskReviewSheet(
                task: task,
                onSave: { updated in applyEdit(updated) },
                onDelete: { applyDelete(task) },
                onCancel: { editingTask = nil }
            )
            .interactiveDismissDisabled()
            .presentationDetents([.large])
        }
    }

    private var doneState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Color(hex: "25924A"))
            Text("All caught up").font(Typography.font(20, weight: .heavy)).foregroundStyle(EColor.onSurface)
            Text("You've been through every task for \(childName).")
                .font(Typography.font(13, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Done") { dismiss(); onDismiss() }
                .padding(.top, 8)
        }
        .padding(28)
    }

    @ViewBuilder
    private func actionButtons(for task: ChildTask) -> some View {
        if isResolved(task) {
            Button {
                approve(task) // idempotent for an already-resolved task — just advances the deck
            } label: {
                Label("Next task", systemImage: "arrow.right")
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                if let secondary = secondaryLabel(for: task) {
                    Button {
                        showRedoCompose = true
                    } label: {
                        Label(secondary, systemImage: "arrow.uturn.backward")
                            .font(Typography.font(15, weight: .heavy))
                            .foregroundStyle(Color(hex: "B26A00"))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: "EF6C00"), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    approve(task)
                } label: {
                    Label(primaryLabel(for: task), systemImage: "checkmark")
                        .font(Typography.font(15, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Brand.greenDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func approve(_ task: ChildTask) {
        if let occId = task.occurrenceId {
            BackendWrite.run("Approving the task") { _ = try await APIClient.shared.approveTask(occurrenceId: occId) }
        }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i].state = task.state == .bypass ? .bypassed : .done
        }
        unlockIfEverythingResolved()
        // Same fly-off-right whether this came from a swipe or the Approve
        // button — the transition means "approved", not "you dragged it".
        withAnimation(.easeIn(duration: 0.18)) { dragOffset = CGSize(width: 520, height: dragOffset.height) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            dragOffset = .zero
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { advance() }
        }
    }

    // Mirrors ScreenProfile's approveAllPendingReview() — approving the
    // last outstanding task one at a time through this deck should earn
    // the same automatic unlock that bulk-approving everything at once
    // does, not leave the child stuck locked with nothing actually left to
    // do. Only fires while genuinely locked *for* tasks — a parent's own
    // manual lock (.locked) is a separate, deliberate decision that
    // approving a task was never meant to override.
    private func unlockIfEverythingResolved() {
        guard let childId, FamilyStore.child(childId).status == .lockedTasks else { return }
        let stillOutstanding = tasks.contains { $0.state == .pending || $0.state == .review || $0.state == .overdue || $0.state == .bypass }
        guard !stillOutstanding else { return }
        let child = FamilyStore.child(childId)
        child.timeLeft = formatMinutes(child.dailyLimitMin)
        child.timePct = 100
    }

    private func applyRedo(note: String, hasVoice: Bool) {
        guard let task = currentTask, let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].state = .pending
        tasks[i].redoNote = note.isEmpty ? nil : note
        tasks[i].redoHasVoiceNote = hasVoice
        // Send the redo (and the note) to the server so the kid sees it and a
        // sync doesn't put the task back in review.
        if let occId = task.occurrenceId {
            BackendWrite.run("The redo request") { try await APIClient.shared.rejectTask(occurrenceId: occId, note: note) }
        }
    }

    private func applyEdit(_ updated: ChildTask) {
        BackendWrite.run("Your task edit") {
            _ = try await APIClient.shared.updateTask(
                taskId: updated.id,
                title: updated.title,
                instructions: updated.description,
                recurrence: updated.repeats,
                category: updated.category,
                submissionKind: updated.photoCount > 0 ? "photo" : "none"
            )
        }
        if let i = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[i] = updated
        }
        editingTask = nil
    }

    private func applyDelete(_ task: ChildTask) {
        BackendWrite.run("Deleting the task") { _ = try await APIClient.shared.deleteTask(taskId: task.id) }
        tasks.removeAll { $0.id == task.id }
        editingTask = nil
    }

    private func advance() {
        index += 1
    }

    // MARK: - Tinder-style card stack

    // A faint peek of the next card sitting behind the current one — the
    // same stacked-deck read Tinder has — plus the current card itself,
    // draggable only when there's an actual decision a drag could mean
    // (task.state == .review: the kid submitted something, nothing to
    // decide otherwise).
    @ViewBuilder
    private func cardStack(for task: ChildTask) -> some View {
        ZStack {
            if tasks.indices.contains(index + 1) {
                TaskReviewCard(task: tasks[index + 1], childName: childName)
                    .scaleEffect(0.94)
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
            if task.state == .review {
                swipeableCard(for: task)
            } else {
                TaskReviewCard(task: task, childName: childName)
            }
        }
    }

    private func swipeableCard(for task: ChildTask) -> some View {
        // Tracks toward the threshold only, not the raw pixel distance —
        // a stamp fully visible well before the drag would actually
        // commit reads as "you've done enough," which is the wrong signal.
        let progress = min(abs(dragOffset.width) / swipeThreshold, 1)
        return TaskReviewCard(task: task, childName: childName)
            .rotationEffect(.degrees(Double(dragOffset.width / 16)))
            .offset(dragOffset)
            .overlay(alignment: .topLeading) {
                swipeStamp("APPROVE", systemImage: "checkmark.circle.fill", tint: Color(hex: "25924A"))
                    .opacity(dragOffset.width > 0 ? progress : 0)
                    .rotationEffect(.degrees(-12))
                    .padding(20)
            }
            .overlay(alignment: .topTrailing) {
                swipeStamp("REDO", systemImage: "arrow.uturn.backward.circle.fill", tint: Color(hex: "EF6C00"))
                    .opacity(dragOffset.width < 0 ? progress : 0)
                    .rotationEffect(.degrees(12))
                    .padding(20)
            }
            // simultaneousGesture, not gesture — TaskReviewCard's body is
            // itself a ScrollView (a long submission can need real
            // vertical scrolling), and a plain .gesture() here would claim
            // the touch outright and block that scroll, the same conflict
            // this file's old pager comment described. Running alongside
            // the ScrollView's own pan instead, filtered to horizontal-
            // dominant drags only, leaves vertical scrolling untouched.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width > swipeThreshold {
                            approve(task)
                        } else if value.translation.width < -swipeThreshold {
                            // Leans the card out; the compose sheet (opened
                            // below) is the real commit — see its onSend/
                            // onCancel for how the card actually resolves.
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = CGSize(width: -swipeThreshold * 0.6, height: 0)
                            }
                            showRedoCompose = true
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
                        }
                    }
            )
    }

    private func swipeStamp(_ label: String, systemImage: String, tint: Color) -> some View {
        Label(label, systemImage: systemImage)
            .font(Typography.font(18, weight: .heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint, lineWidth: 3))
    }
}

// One card's worth of the task under review — condensed from the full
// TaskDetailSheet layout to fit a swipeable card instead of a scroll view.
private struct TaskReviewCard: View {
    var task: ChildTask
    var childName: String

    // Which photo a tap in the grid should open the full-screen viewer to
    // — set together right before showPhotoViewer flips true, so the
    // viewer never has a stale/mismatched starting page.
    @State private var viewerIndex = 0
    @State private var showPhotoViewer = false

    private var statusMeta: (label: String, tone: Color, bg: Color) {
        switch task.state {
        case .done: return ("Approved", Color(hex: "25924A"), Color(hex: "25924A").opacity(0.10))
        case .bypassed: return ("Bypassed", EColor.onSurfaceVariant, EColor.outlineVariant.opacity(0.5))
        case .review: return ("Awaiting your review", Color(hex: "B26A00"), Color(hex: "FFA726").opacity(0.12))
        case .overdue: return ("Overdue · not submitted", EColor.danger, EColor.danger.opacity(0.10))
        case .bypass: return ("Bypass requested", Color(hex: "7C3AED"), Color(hex: "7C3AED").opacity(0.10))
        case .pending: return ("Waiting on \(childName)", EColor.onSurfaceVariant, EColor.outlineVariant.opacity(0.5))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    // No category label above the title anymore — it was
                    // small, rarely useful (the title already says what
                    // the task is), and just ate space the title could
                    // use instead.
                    Text(task.title)
                        .font(Typography.font(30, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)

                    if task.state == .review {
                        // Routine, positive state — the kid already did the
                        // work, there's nothing here to flag — so this skips
                        // the colored "Awaiting your review" pill every other
                        // state gets (same reasoning as ScreenProfile's own
                        // review-state declutter) and shows nothing here at
                        // all: the due date isn't worth surfacing once the
                        // work's already been turned in.
                    } else {
                        HStack(spacing: 8) {
                            Circle().fill(statusMeta.tone).frame(width: 7, height: 7)
                            Text(statusMeta.label).font(Typography.font(12, weight: .bold)).foregroundStyle(statusMeta.tone)
                            if let due = task.dueLabel {
                                Spacer(minLength: 8)
                                Text("Due \(due)").font(Typography.font(11, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(statusMeta.bg).clipShape(Capsule())
                    }
                }

                // The photo is the whole point of opening this card — a
                // parent reviewing a submission wants to actually see it,
                // not read instructions first. Moved above "What to do"
                // (which a parent already knows, having assigned it) and
                // sized as large as the card can reasonably give it.
                if task.state != .bypass {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(childName.uppercased())'S SUBMISSION")
                                .font(Typography.font(10, weight: .bold)).tracking(1).foregroundStyle(EColor.onSurfaceVariant)
                            Spacer()
                            if let at = task.submittedAt {
                                Text("at \(at)").font(Typography.font(11, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                            }
                        }
                        if task.photoCount >= 1 {
                            SubmissionPhotoStack(count: task.photoCount) {
                                viewerIndex = 0
                                showPhotoViewer = true
                            }
                        } else {
                            emptySubmissionPlaceholder
                        }
                    }
                }

                if !task.description.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHAT TO DO").font(Typography.font(9.5, weight: .bold)).tracking(1).foregroundStyle(EColor.onSurfaceVariant)
                        Text(task.description)
                            .font(Typography.font(13, weight: .regular))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }
                }

                if let note = task.note, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(childName.uppercased())'S NOTE").font(Typography.font(10, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant)
                        Text("\"\(note)\"").font(Typography.font(13.5, weight: .regular)).foregroundStyle(EColor.onSurface)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // A bit more separation from the submission photo above
                    // than the card's usual rhythm — on top of the outer
                    // VStack's own 22pt spacing, so the note reads as its
                    // own beat instead of sitting right under the photo.
                    .padding(.top, 10)
                }

                if task.hasVoiceNote {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(hex: "7C3AED"))
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice note").font(Typography.font(13.5, weight: .bold)).foregroundStyle(EColor.onSurface)
                            Text("From \(childName)").font(Typography.font(11.5, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color(hex: "7C3AED").opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No rubber-band overscroll when the content already fits — one
        // less way this card's own scroll can still be "settling" for a
        // beat after a drag ends, which is what made the outer swipe-to-
        // next-task pager feel unresponsive right after scrolling here.
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(EColor.outlineVariant.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
        .fullScreenCover(isPresented: $showPhotoViewer) {
            PhotoGalleryViewer(count: task.photoCount, index: $viewerIndex, onClose: { showPhotoViewer = false })
        }
    }

    private var emptySubmissionPlaceholder: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(EColor.surfaceContainerHigh).frame(width: 48, height: 48)
                Image(systemName: task.state == .overdue ? "exclamationmark" : "hourglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(EColor.outline)
            }
            Text(task.state == .overdue ? "No photo submitted" : "Waiting for photo")
                .font(Typography.font(13, weight: .bold)).foregroundStyle(EColor.onSurface)
            Text(task.state == .overdue ? "\(childName) missed the deadline" : "\(childName) hasn't uploaded yet")
                .font(Typography.font(11.5, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(EColor.outlineVariant)
        )
    }

}

// A layered stack rather than a flat grid — the front (first) photo shown
// full-size and in focus, with the next couple of pages peeking out from
// behind at a slight rotation/offset, Instagram-multi-photo-post style
// (its carousel indicator + the physical feel of a small stack of instant
// photos). Reads at a glance as "one submission, several pages" instead of
// making a parent scan a grid of equally-weighted tiles before knowing
// what they're even looking at. Tapping opens PhotoGalleryViewer at the
// first page; swiping/the thumbnail strip there reaches the rest.
private struct SubmissionPhotoStack: View {
    var count: Int
    var onTap: () -> Void

    // As large as the card can reasonably give it — this is the whole
    // point of opening the card, not a supporting detail.
    private let stackHeight: CGFloat = 340

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                let photoWidth = geo.size.width * 0.93
                ZStack {
                    if count >= 3 {
                        MockHomeworkPhoto(pageNumber: 3)
                            .frame(width: photoWidth, height: stackHeight - 24)
                            .rotationEffect(.degrees(6))
                            .offset(x: geo.size.width * 0.025, y: 10)
                            .opacity(0.75)
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    }
                    if count >= 2 {
                        MockHomeworkPhoto(pageNumber: 2)
                            .frame(width: photoWidth, height: stackHeight - 24)
                            .rotationEffect(.degrees(-4))
                            .offset(x: -geo.size.width * 0.02, y: 5)
                            .opacity(0.88)
                            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                    }
                    MockHomeworkPhoto(pageNumber: 1, detailed: true)
                        .frame(width: photoWidth, height: stackHeight - 24)
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                        .overlay(alignment: .topTrailing) {
                            if count > 1 {
                                HStack(spacing: 3) {
                                    Image(systemName: "square.stack.fill").font(.system(size: 10, weight: .bold))
                                    Text("\(count)").font(Typography.font(11, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .padding(10)
                            }
                        }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: stackHeight)
        }
        .buttonStyle(.plain)
    }
}

// A stand-in "photographed homework page" — ruled lines, a bit of
// handwriting-like scribble, a checkmark — used for both the grid
// thumbnail and (scaled up) the full-screen viewer, so tapping a thumbnail
// visibly opens "the same photo" bigger rather than a generic gray box.
// There's no real camera capture in this prototype (see TaskDetailView),
// so this is what a submitted photo looks like everywhere it appears.
// Not private — TaskDetailView (kid side) reuses this same mock
// "photographed page" visual for its own multi-photo capture UI, so a
// submitted photo looks identical whichever side is looking at it.
struct MockHomeworkPhoto: View {
    var pageNumber: Int
    var detailed: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: detailed ? 20 : 12, style: .continuous)
                    .fill(Color(hex: "FFFDF6"))

                VStack(alignment: .leading, spacing: geo.size.height / (detailed ? 11 : 7)) {
                    ForEach(0..<(detailed ? 9 : 5), id: \.self) { _ in
                        Rectangle().fill(Color(hex: "E4DFCE")).frame(height: 1)
                    }
                }
                .padding(.top, geo.size.height * 0.28)
                .padding(.horizontal, geo.size.width * 0.12)

                Text("Page \(pageNumber)")
                    .font(Typography.font(detailed ? 15 : 9, weight: .bold))
                    .foregroundStyle(Color(hex: "8A8064"))
                    .padding(.top, geo.size.height * 0.1)
                    .padding(.leading, geo.size.width * 0.12)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: geo.size.width * 0.16))
                    .foregroundStyle(Brand.greenDeep.opacity(0.55))
                    .rotationEffect(.degrees(-12))
                    .position(x: geo.size.width * 0.82, y: geo.size.height * 0.8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: detailed ? 20 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: detailed ? 20 : 12, style: .continuous).strokeBorder(Color(hex: "E4DFCE"), lineWidth: 1))
    }
}

// MARK: - Full-screen photo viewer

// Opened by tapping any tile in submissionPhotoGrid. What makes switching
// between several pages easy for a parent skimming a submission: page-
// swipe, a direct-jump thumbnail strip so they don't have to swipe past
// pages one at a time, swipe-down-to-dismiss (Photos/Messages-style), and
// now swiping past the last page also exits back to the task card, so a
// parent who's just paging through doesn't have to reach for Close at all.
//
// A hand-built pager (ScrollView + .paging), not TabView(.page) — same
// reason as TaskReviewDeckView's pager above: pinch-to-zoom needs a plain
// DragGesture for panning while zoomed, and that would otherwise fight
// TabView(.page)'s own paging gesture the same way a nested vertical
// ScrollView did. Disabling the pager's own scroll while any page is
// zoomed in (.scrollDisabled(isZoomed)) is what keeps the two from
// fighting: panning a zoomed photo can't also change pages, and once
// zoomed back out, normal swipe-between-photos comes right back.
private struct PhotoGalleryViewer: View {
    var count: Int
    @Binding var index: Int
    var onClose: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var scrollPosition: Int?
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        ZoomablePhotoPage(pageNumber: i + 1, isZoomed: $isZoomed)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                    // Sentinel: swiping one more page past the last real
                    // photo lands here, which immediately exits instead of
                    // just bouncing at the end.
                    Color.clear
                        .containerRelativeFrame(.horizontal)
                        .id(count)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition)
            .scrollDisabled(isZoomed)
            .scrollIndicators(.hidden)
            .onChange(of: scrollPosition) { _, newValue in
                guard let newValue else { return }
                if newValue == count {
                    onClose()
                    return
                }
                guard newValue != index else { return }
                index = newValue
                isZoomed = false
            }
            .onChange(of: index) { _, newValue in
                guard scrollPosition != newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition = newValue }
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
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Direct-jump strip — faster than swiping through several
                // pages one at a time to find a specific one. Hidden while
                // zoomed so it can't be mistaken for another zoom target.
                if count > 1, !isZoomed {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(0..<count, id: \.self) { i in
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) { index = i }
                                    } label: {
                                        MockHomeworkPhoto(pageNumber: i + 1)
                                            .frame(width: 46, height: 60)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(.white, lineWidth: index == i ? 2.5 : 0)
                                            )
                                            .opacity(index == i ? 1 : 0.55)
                                    }
                                    .buttonStyle(.plain)
                                    .id(i)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .onChange(of: index) { _, newValue in
                            withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                        }
                    }
                    .padding(.bottom, 26)
                }
            }
        }
        .offset(y: dragOffset)
        // Only a mostly-vertical drag counts, so this doesn't fight the
        // pager's own horizontal swipe-between-photos gesture — and none
        // of it applies while zoomed, where a drag means "pan the photo,"
        // not "dismiss."
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

// Pinch (or double-tap) to zoom, drag to pan while zoomed. Reports zoom
// state up via the shared `isZoomed` binding so PhotoGalleryViewer can
// disable its own pager while this is active — see that struct's header
// comment for why that's what keeps zoom-panning from also flipping pages.
// Attached with .simultaneousGesture (not .gesture) so, at 1x, this never
// competes with the pager's own swipe recognition — the pan half is a
// no-op there anyway (guarded on scale > 1).
private struct ZoomablePhotoPage: View {
    var pageNumber: Int
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
        let photo = MockHomeworkPhoto(pageNumber: pageNumber, detailed: true)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .padding(.horizontal, 28)
            .scaleEffect(scale)
            .offset(offset)

        // The pan gesture is only attached at all while actually zoomed
        // in — a `guard scale > 1` inside its closures wasn't enough:
        // even a no-op DragGesture recognizer still competes for the same
        // single-finger touch the pager wants for swipe-between-photos,
        // which is what broke normal swiping after zoom was added. With
        // no drag recognizer present at 1x at all, there's nothing left to
        // compete with the pager. Magnify alone (2-finger) never conflicts
        // with a 1-finger swipe, so it stays attached either way.
        Group {
            if isZoomed {
                photo.simultaneousGesture(magnify.simultaneously(with: pan))
            } else {
                photo.simultaneousGesture(magnify)
            }
        }
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.25)) {
                    if scale > 1 {
                        resetZoom()
                    } else {
                        scale = 2.5; lastScale = 2.5
                        isZoomed = true
                    }
                }
            }
    }
}

// Shown on Redo — a quick note and/or a (mocked, no real audio — matches
// the kid-side task-photo capture pattern in TaskDetailView) voice note the
// parent sends back explaining what needs fixing.
// Same FormShell/FormField shell AddTaskForm uses (Cancel top-left, big
// bold title, full-width Save pill) rather than a bespoke layout, so every
// parent-facing compose sheet in the app reads as one consistent pattern.
private struct RedoComposeSheet: View {
    var childName: String
    var taskTitle: String
    var actionLabel: String
    var onSend: (String, Bool) -> Void
    var onCancel: () -> Void

    @State private var note = ""
    @State private var voiceRecorded = false

    private var canSend: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceRecorded }

    var body: some View {
        FormShell(
            title: actionLabel,
            onCancel: onCancel,
            onSave: { onSend(note.trimmingCharacters(in: .whitespacesAndNewlines), voiceRecorded) },
            canSave: canSend,
            saveLabel: "Send & \(actionLabel.lowercased())"
        ) {
            Text(taskTitle)
                .font(Typography.font(13, weight: .semibold))
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.bottom, 14)

            FormField(label: "Let \(childName) know why") {
                TextField("e.g. Missed the desk, can you go back and wipe it down?", text: $note, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .lineLimit(3...5)
                    .padding(14)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button {
                voiceRecorded.toggle()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(voiceRecorded ? FormGreen.accent : FormGreen.accentBg)
                        Image(systemName: voiceRecorded ? "checkmark" : "mic.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(voiceRecorded ? .white : FormGreen.accent)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(voiceRecorded ? "Voice note attached" : "Record a voice note")
                            .font(Typography.font(14, weight: .heavy)).foregroundStyle(EColor.onSurface)
                        Text(voiceRecorded ? "Tap to remove" : "Say it instead of typing it")
                            .font(Typography.font(12, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(EColor.surfaceContainerLowest)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EColor.outlineVariant))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)

            Button("\(actionLabel) without a note") { onSend("", false) }
                .font(Typography.font(13, weight: .semibold))
                .foregroundStyle(EColor.onSurfaceVariant)
                .frame(maxWidth: .infinity)
        }
    }
}

// Opened from the "..." button on the review deck's toolbar — same
// FormShell/FormField shell AddTaskSheet uses, pre-filled from the task
// under review, plus a Delete action (ScreenProfile's AddTaskSheet has no
// delete equivalent since it only ever creates).
private struct EditTaskReviewSheet: View {
    var task: ChildTask
    var onSave: (ChildTask) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var dueDate = Date()
    @State private var hasDueDate: Bool
    @State private var repeatDays: Set<String>
    @State private var showDeleteConfirm = false
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    init(task: ChildTask, onSave: @escaping (ChildTask) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _hasDueDate = State(initialValue: task.dueLabel != nil)
        _dueDate = State(initialValue: Self.parseDueDate(task.dueLabel))
        _repeatDays = State(initialValue: task.repeats == "none"
            ? []
            : Set(task.repeats.split(separator: ",").map(String.init)))
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(title: "Edit task", onCancel: onCancel, onSave: {
            var updated = task
            updated.title = title.trimmingCharacters(in: .whitespaces)
            updated.description = description
            updated.dueLabel = hasDueDate ? formatted(dueDate) : nil
            updated.dueDate = hasDueDate ? dueDate : nil
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            updated.repeats = repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
            onSave(updated)
        }, canSave: canSave, saveLabel: "Save changes", onDelete: { showDeleteConfirm = true }) {
            FormField(label: "Task name") {
                FormTextField(placeholder: "e.g. Make your bed", text: $title, scrollToTopOnFocus: true)
            }
            RepeatPicker(selectedDays: $repeatDays)
            // Starts expanded when there's already something to show
            // (a due date already set, or existing instructions) so
            // editing a task doesn't hide its own current values behind
            // an extra tap — a brand-new task has nothing to hide, so
            // AddTaskSheet's version of this always starts closed instead.
            MoreOptions(startOpen: hasDueDate || !description.isEmpty) {
                TaskWhenField(hasDueDate: $hasDueDate, dueDate: $dueDate)
                FormField(label: "What to do") {
                    TextField("Instructions for the student…", text: $description, axis: .vertical)
                        .font(Typography.font(15, weight: .regular))
                        .lineLimit(3...5)
                        .padding(14)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onChange(of: description) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollFormToBottom()
                            }
                        }
                }
            }
        }
        .alert("Delete \"\(task.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f.string(from: date)
    }

    // task.dueLabel is a freeform display string ("Today, 6:00 PM",
    // "Yesterday, 5:00 PM") from mock data, not a stored Date — pulling
    // just the trailing clock time out of it and pinning it to today is a
    // reasonable stand-in given there's no real backing Date to read, and
    // fixes editing a scheduled task from showing the current live time
    // as if that were its actual due time.
    private static func parseDueDate(_ label: String?) -> Date {
        guard let label, let timeToken = label.split(separator: ",").last else { return Date() }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        guard let time = f.date(from: timeToken.trimmingCharacters(in: .whitespaces)) else { return Date() }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
    }
}
