import SwiftUI
import UIKit

// Task review — opened when a parent taps a task row. Swipe horizontally
// to browse between tasks (a hand-built ScrollView pager — see below),
// Approve/Redo as plain buttons below the card. Used to be a Tinder-style
// swipeable card (drag left/right to *decide* approve/redo, with a stamp/
// fly-off animation) — that was removed by direct request and stays
// removed. This is a different, older mechanic from before this app had a
// backend at all (see git history around "Fix sluggish swipe-between-
// tasks"): swiping just navigates, same as Photos/Mail paging between
// attachments — deciding is still only ever a deliberate button tap.
// A Redo always pauses on a small compose step first so the parent can send
// the kid a quick note about what to fix.
struct TaskReviewDeckView: View {
    // The tasks the deck pages through, read live from the phone's database
    // (TaskStore), so an approval or edit made here shows here and on Home
    // at once. A task the parent has decided (approved, sent back, skip
    // allowed) leaves the deck, and the next one slides into its place.
    var childName: String
    var childId: String
    var onDismiss: () -> Void

    @State private var deckIds: [String]
    private var tasks: [ChildTask] { TaskStore.tasks(for: childId, ids: deckIds) }

    @Environment(\.dismiss) private var dismiss
    // The task on screen, by id: the pager's position, and what a sync or a
    // delete keeps the deck on.
    @State private var currentId: String?
    // The task just decided, for the beat its stamp shows before it leaves.
    // Buttons hold still meanwhile, so they never flash the next state.
    @State private var leavingId: String?
    // The task as it looked when decided, shown until it slides away, so
    // the card doesn't change under the "Approved" / "Sent back" bar.
    @State private var frozen: ChildTask?
    @State private var leavingApproved = true
    // Where the Approve button and the "Approved" bar share one shape.
    @Namespace private var buttonSpace
    @State private var pendingRedo: (ChildTask, String)?
    @State private var showRedoCompose = false
    @State private var editingTask: ChildTask?
    // Drives the finished screen's pop-in and its success tap.
    @State private var doneAppeared = false
    // Set only by an approval that leaves nothing to check. Swiping past
    // the last task, opening a deck of already-done tasks, or sending one
    // back never shows it.
    @State private var showCaughtUp = false
    @State private var approvedTick = 0
    @State private var sentBackTick = 0
    @State private var pagedTick = 0
    // How far a sideways drag has moved the task, so it follows the finger.
    @State private var cardDrag: CGFloat = 0
    // The task's opacity, for the fade-in after a cut.
    @State private var cardFade: Double = 1
    // Approving throws the card off to the right, tilted, with a stamp, while
    // the next task (upcomingId) grows into place underneath.
    @State private var throwOffset: CGSize = .zero
    @State private var throwAngle: Double = 0
    @State private var stampShown = false
    @State private var upcomingId: String?
    @State private var incomingX: CGFloat = 400
    @State private var dragSideways: Bool?


    private func buttonsKey(for task: ChildTask) -> String {
        "\(primaryLabel(for: task))|\(secondaryLabel(for: task) ?? "")|\(isResolved(task))"
    }

    // One task's card: white, rounded, hairline border.
    private func cardFace(_ task: ChildTask) -> some View {
        TaskReviewCard(task: task, childName: childName)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EColor.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
    }

    private var upcomingTask: ChildTask? {
        upcomingId.flatMap { id in TaskStore.tasks(for: childId, ids: [id]).first }
    }

    // Pops up in the middle of the card the moment it's decided, fast and a
    // little springy, then slides off with the task: a green circle with a
    // check for an approval, an orange one with a back-arrow for a redo.
    private var decidedPop: some View {
        Image(systemName: leavingApproved ? "checkmark" : "arrow.uturn.backward")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(leavingApproved ? Brand.greenDeep : Color(hex: "EF6C00"), in: Circle())
            .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
            .scaleEffect(stampShown ? 1 : 0.5)
            .opacity(stampShown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel(leavingApproved ? "Approved" : "Sent back for a redo")
    }

    private var allOfTodayApproved: Bool {
        let today = TaskStore.tasks(for: childId).filter(\.isDueToday)
        return !today.isEmpty && today.allSatisfy { $0.state == .done || $0.state == .bypassed }
    }

    private func canStep(by delta: Int) -> Bool {
        guard let i = deckIds.firstIndex(of: currentTask?.id ?? "") else { return false }
        return deckIds.indices.contains(i + delta)
    }

    // One thin segment per task in the deck, Instagram-style, no numbers:
    // where you are in the order, nothing else. Filled up to and including
    // the task on screen; whether a task is approved doesn't fill it.
    private var progressSegments: some View {
        let current = deckIds.firstIndex(of: currentTask?.id ?? "") ?? 0
        return HStack(spacing: 4) {
            ForEach(Array(deckIds.enumerated()), id: \.element) { i, _ in
                Capsule()
                    .fill(i <= current ? EColor.onSurface : HomeStyle.line)
                    .frame(height: 3)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: current)
        .animation(.spring(duration: 0.3, bounce: 0), value: deckIds)
        .accessibilityHidden(true)
    }

    private func edgeTapZone(_ action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 68)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
    }

    // A tap at an edge: the same move as a swipe. At either end there's
    // nothing that way, so the card gives a small nudge instead.
    private func tapStep(by delta: Int) {
        guard leavingId == nil else { return }
        if canStep(by: delta) { step(by: delta); return }
        withAnimation(.spring(duration: 0.12, bounce: 0)) { cardDrag = CGFloat(-delta) * 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { cardDrag = 0 }
        }
    }

    // The next task or the one before, stopping at the ends. From a swipe,
    // the card first carries on off the side it was dragged toward, then
    // the next cuts in; from a tap, it just cuts.
    private func step(by delta: Int, fromSwipe: Bool = false) {
        guard let i = deckIds.firstIndex(of: currentTask?.id ?? ""),
              deckIds.indices.contains(i + delta) else { return }
        pagedTick += 1
        let next = deckIds[i + delta]
        guard fromSwipe else {
            cut { currentId = next; cardDrag = 0 }
            return
        }
        // Each move starts in an update of its own. Changes landing in the
        // same update merge, and the instant placement's "no animation"
        // won: the card jumped off, and the next one jumped in.
        // The card's width plus its margins: just past the edge.
        let offEdge: CGFloat = 384
        DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.12)) { cardDrag = CGFloat(-delta) * offEdge }
        }
        // As it leaves: the next is placed just past the far edge...
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withoutAnimation { currentId = next; cardDrag = CGFloat(delta) * offEdge }
            // ...and slides in once that placement is on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(.spring(duration: 0.3, bounce: 0)) { cardDrag = 0 }
            }
        }
    }

    init(taskIds: [String], childName: String, childId: String, startIndex: Int, onDismiss: @escaping () -> Void) {
        self.childName = childName
        self.childId = childId
        self.onDismiss = onDismiss
        _deckIds = State(initialValue: taskIds)
        _currentId = State(initialValue: taskIds.indices.contains(startIndex) ? taskIds[startIndex] : taskIds.first)
    }

    private var currentTask: ChildTask? { tasks.first { $0.id == currentId } ?? tasks.first }

    // The two buttons per state. Submitted (.review): Approve or Redo.
    // Asked to skip (.bypass): Skip for now, or Keep it (back to to-do).
    // Approved (.done): Next task, or Redo if the parent changes their
    // mind. Skipped (.bypassed) is final: Next only.
    private func primaryLabel(for task: ChildTask) -> String {
        switch task.state {
        case .bypass: return "Skip for now"
        case .done: return "Next task"
        default: return "Approve"
        }
    }
    private func secondaryLabel(for task: ChildTask) -> String? {
        switch task.state {
        case .review, .done: return "Redo"
        // "Keep it": the task stays on today, without sounding like a no.
        case .bypass: return "Keep it"
        default: return nil
        }
    }
    private func isResolved(_ task: ChildTask) -> Bool { task.state == .bypassed }
    private func isComplete(_ task: ChildTask) -> Bool { task.state == .done || task.state == .bypassed }

    var body: some View {
        NavigationStack {
            ZStack {
                EColor.surface.ignoresSafeArea()

                if showCaughtUp {
                    doneState
                        .transition(.opacity)
                } else if !tasks.isEmpty {
                    VStack(spacing: 0) {
                        if deckIds.count > 1 {
                            progressSegments
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                        }
                        // One white card that stays put; the task inside it
                        // changes with a cut (see the transition below). A
                        // sideways swipe drags the task, and carries it off
                        // that side before the next cuts in.
                        ZStack {
                            // While an approved card is thrown, the next task
                            // waits underneath, a little smaller, and grows
                            // into place as the top one leaves (as Tinder's
                            // stack does), so there's no cut and no gap.
                            if let upcoming = upcomingTask {
                                cardFace(upcoming)
                                    .offset(x: incomingX)
                                    .id("under-\(upcoming.id)")
                                    .transition(.identity)
                            }
                            if let task = currentTask {
                                // Moving on is otherwise a cut, as between one
                                // person's Instagram stories: the old task
                                // goes and the next fades in (cut); a swipe
                                // moves the card like a page (step). All
                                // driven by state on the card's outer frame:
                                // transitions, and moving what's inside the
                                // task's scroll view, never animated.
                                cardFace(frozen?.id == task.id ? frozen! : task)
                                    .overlay {
                                        if leavingId == task.id { decidedPop }
                                    }
                                    .rotationEffect(.degrees(throwAngle), anchor: .bottom)
                                    .offset(x: cardDrag + throwOffset.width, y: throwOffset.height)
                                    .opacity(cardFade)
                                    .id(task.id)
                                    // Swapped instantly whatever else is
                                    // animating at that moment.
                                    .transition(.identity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Tap the right edge for the next task, the left edge
                        // for the one before, as in Instagram stories. Only
                        // the edges: the middle stays the card's own (the
                        // photo opens, the text scrolls).
                        .overlay {
                            HStack(spacing: 0) {
                                edgeTapZone { tapStep(by: -1) }
                                Spacer(minLength: 0)
                                edgeTapZone { tapStep(by: 1) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        // The task follows the finger, with resistance at the
                        // ends; far or fast enough moves on, else it springs back.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 12)
                                .onChanged { v in
                                    let dx = v.translation.width, dy = v.translation.height
                                    // Decided once per drag: sideways, or a
                                    // scroll through the card.
                                    if dragSideways == nil { dragSideways = abs(dx) > abs(dy) * 1.5 }
                                    guard leavingId == nil, dragSideways == true else { return }
                                    cardDrag = canStep(by: dx < 0 ? 1 : -1) ? dx * 0.6 : dx * 0.15
                                }
                                .onEnded { v in
                                    defer { dragSideways = nil }
                                    guard dragSideways == true else { return }
                                    let dx = v.translation.width
                                    let projected = v.predictedEndTranslation.width
                                    let delta = dx < 0 ? 1 : -1
                                    if leavingId == nil, abs(dx) > 70 || abs(projected) > 160, canStep(by: delta) {
                                        step(by: delta, fromSwipe: true)
                                    } else if cardDrag != 0 {
                                        withAnimation(.spring(duration: 0.3, bounce: 0)) { cardDrag = 0 }
                                    }
                                }
                        )
                        .accessibilityAction(named: "Next task") { step(by: 1) }
                        .accessibilityAction(named: "Previous task") { step(by: -1) }
                        // A task deleted or gone under the deck: stay on the
                        // nearest one.
                        .onChange(of: tasks.map(\.id)) { _, ids in
                            if let currentId, ids.contains(currentId) { return }
                            currentId = ids.first
                        }

                        if let task = currentTask {
                            // Keyed by what the buttons say, so a change
                            // ("Approve" to "Approved") cross-fades instead
                            // of jumping; the same buttons for the next task
                            // stay still. Layered, so mid-fade the old and the
                            // new sit in the same place: in the column they
                            // stacked for a moment and the card jumped.
                            ZStack {
                                Group {
                                    if leavingId == task.id {
                                        DecidedBar(approved: leavingApproved, space: buttonSpace)
                                    } else {
                                        actionButtons(for: task)
                                    }
                                }
                                .id(leavingId == task.id ? "decided" : buttonsKey(for: task))
                                .transition(.opacity)
                            }
                            .frame(height: 52)
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 20)
                    .animation(.easeOut(duration: 0.2), value: currentTask == nil)
                }
            }
            .animation(.easeOut(duration: 0.25), value: showCaughtUp)
            // One haptic per decision, at the tap: success for an approval,
            // a soft tap for sending back, a tick for paging.
            // Approving: success the instant the green card pops.
            .sensoryFeedback(.success, trigger: approvedTick)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: sentBackTick)
            .sensoryFeedback(.selection, trigger: pagedTick)
            // Deleting the last task leaves nothing to review: close rather
            // than claim everything was completed.
            .onChange(of: tasks.isEmpty) { _, isEmpty in
                if isEmpty && !showCaughtUp { dismiss(); onDismiss() }
            }
            .navigationTitle(childName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss(); onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let task = currentTask, !showCaughtUp {
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
        // The send-back runs once the sheet has fully gone, not while it's
        // still sliding down: one thing moving at a time.
        .sheet(isPresented: $showRedoCompose, onDismiss: {
            guard let (task, note) = pendingRedo else { return }
            pendingRedo = nil
            decide(task, approved: false) { TaskEdits.redo(task, note: note, childId: childId) }
        }) {
            Group {
            if let task = currentTask {
                RedoComposeSheet(childName: childName, taskTitle: task.title, actionLabel: secondaryLabel(for: task) ?? "Redo", onSend: { note in
                    pendingRedo = (task, note)
                    showRedoCompose = false
                }, onCancel: {
                    showRedoCompose = false
                })
                .presentationDetents([.large])
            }
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingTask) { task in
            Group {
            EditTaskReviewSheet(
                task: task,
                onSave: { updated in applyEdit(updated) },
                onDelete: { applyDelete(task) },
                onCancel: { editingTask = nil }
            )
            .presentationDetents([.large])
        }
            .presentationDragIndicator(.visible)
        }
    }

    // The end of the deck is a small win for the parent, so it says so:
    // the badge pops in, the phone gives a success tap, and the words are
    // praise rather than a status report.
    private var doneState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(hex: "25924A").opacity(0.12)).frame(width: 104, height: 104)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Color(hex: "25924A"))
            }
            .scaleEffect(doneAppeared ? 1 : 0.6)
            .opacity(doneAppeared ? 1 : 0)
            .padding(.bottom, 6)
            Text("Great job!").font(Typography.font(26, weight: .heavy)).foregroundStyle(EColor.onSurface)
            Text("You've checked everything for \(childName). Keep up the good work.")
                .font(Typography.font(15, weight: .medium)).foregroundStyle(EColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Done") { dismiss(); onDismiss() }
                .padding(.top, 10)
        }
        .padding(28)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { doneAppeared = true }
        }
    }

    @ViewBuilder
    private func actionButtons(for task: ChildTask) -> some View {
        if isResolved(task) {
            Button {
                showNext(after: task.id)
            } label: {
                Label("Next task", systemImage: "arrow.right")
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant, lineWidth: 1.5))
            }
            .buttonStyle(PressScaleStyle())
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
                    .buttonStyle(PressScaleStyle())
                }

                Button {
                    if task.state == .done {
                        showNext(after: task.id)
                    } else {
                        decide(task, approved: true) { TaskEdits.approve(task, childId: childId) }
                    }
                } label: {
                    Label(primaryLabel(for: task), systemImage: "checkmark")
                        .font(Typography.font(15, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background {
                            // The same shape as the "Approved" bar, so on a tap
                            // this button grows into it.
                            RoundedRectangle(cornerRadius: 16).fill(Brand.greenDeep)
                                .matchedGeometryEffect(id: "primaryAction", in: buttonSpace)
                        }
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    // A decision: saved at once (Home shows it straight away), stamped on
    // the card for a beat so it reads as done, then the card leaves.
    private func decide(_ task: ChildTask, approved: Bool, _ write: () -> Void) {
        guard leavingId == nil else { return }
        frozen = task
        write()
        leavingApproved = approved
        if approved { unlockIfEverythingResolved() }
        throwDecided(task, approved: approved)
    }

    // Already decided ("Next task"): page on without taking it out. The
    // last one closes the deck.
    private func showNext(after id: String) {
        guard let i = deckIds.firstIndex(of: id), i + 1 < deckIds.count else { dismiss(); onDismiss(); return }
        pagedTick += 1
        cut { currentId = deckIds[i + 1] }
    }

    // Takes the task out of the deck and slides the next one that still
    // needs the parent into its place. Nothing left: "Great job" after an
    // approval, otherwise the deck just closes.
    /// Where the deck goes after a decision on `id`: the tasks left, and the
    /// next to show, or nil when the deck is done (closes, or "Great job").
    /// An approved task stays in the deck (swipe back to see it); one sent
    /// back is the kid's again, so it leaves the deck and the bar.
    private func plan(after id: String, approved: Bool) -> (remaining: [String], next: String?) {
        let remaining = approved ? deckIds : deckIds.filter { $0 != id }
        let open = TaskStore.tasks(for: childId, ids: remaining).filter { !isComplete($0) && $0.id != id }
        // Nothing left at all: close. Approved the last one still needing the
        // parent: "Great job". Sending one back otherwise keeps the deck open
        // on what's left, completed tasks included.
        guard !remaining.isEmpty, !(approved && open.isEmpty) else { return (remaining, nil) }
        // The next task still needing the parent, after this one, wrapping;
        // with none (sent back from among completed ones), the next card.
        let position = deckIds.firstIndex(of: id) ?? 0
        let order = deckIds.indices.map { deckIds[(position + 1 + $0) % deckIds.count] }.filter { remaining.contains($0) }
        return (remaining, order.first { nextId in open.contains { $0.id == nextId } } ?? order.first)
    }

    // No withAnimation around the deck's changes: the bar animates itself
    // (its own .animation(value:)), and an animation started in the same
    // update carried over onto the card's cut.
    private func moveOn(from id: String, approved: Bool) {
        let (remaining, next) = plan(after: id, approved: approved)
        guard let next else {
            leavingId = nil
            frozen = nil
            if approved && allOfTodayApproved { showCaughtUp = true } else { dismiss(); onDismiss() }
            return
        }
        cut {
            deckIds = remaining
            currentId = next
            leavingId = nil
            frozen = nil
        }
    }

    // An approval, Tinder-style: a firm tap the instant it's pressed, the
    // stamp lands, the card is thrown off to the right with a tilt while the
    // next task grows into place underneath, and the success haptic plays as
    // it goes. About half a second, with no cut and no blank card.
    // A decision, the same way for both: the circle pops up over the task
    // with its haptic (success for an approval, a soft tap for a redo), then
    // the task slides off to the left and the next slides in from the right.
    private func throwDecided(_ task: ChildTask, approved: Bool) {
        let (remaining, next) = plan(after: task.id, approved: approved)
        if approved { approvedTick += 1 } else { sentBackTick += 1 }
        withAnimation(.spring(duration: 0.3, bounce: 0)) { leavingId = task.id }
        withAnimation(.spring(duration: 0.26, bounce: 0.4)) { stampShown = true }
        // Slide: a beat later the green card slides off to the left and the
        // next task slides in from the right, edge to edge, like a page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            guard let next else {
                withoutAnimation { leavingId = nil; frozen = nil; stampShown = false }
                // "Great job" only once every one of today's tasks is
                // approved (or its skip allowed); otherwise just close.
                if approved && allOfTodayApproved { showCaughtUp = true } else { dismiss(); onDismiss() }
                return
            }
            withoutAnimation { upcomingId = next; incomingX = 400 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(.spring(duration: 0.36, bounce: 0)) {
                    throwOffset = CGSize(width: -400, height: 0)
                    incomingX = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // The incoming card, now in place, becomes the card: the same
                // picture, so the swap can't be seen.
                withoutAnimation {
                    deckIds = remaining
                    currentId = next
                    leavingId = nil
                    frozen = nil
                    upcomingId = nil
                    throwOffset = .zero
                    throwAngle = 0
                    stampShown = false
                    incomingX = 400
                }
            }
        }
    }

    // Moves to another task: a cut, the next one fading in (see the card's
    // transition).
    private func cut(_ change: @escaping () -> Void) {
        withoutAnimation { change(); cardFade = 0 }
        // A moment later, so the fade starts from the hidden state rather
        // than merging into the same update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.easeOut(duration: 0.16)) { cardFade = 1 }
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }

    // Mirrors ScreenProfile's approveAllPendingReview() — approving the
    // last outstanding task one at a time through this deck should earn
    // the same automatic unlock that bulk-approving everything at once
    // does, not leave the child stuck locked with nothing actually left to
    // do. Only fires while genuinely locked *for* tasks — a parent's own
    // manual lock (.locked) is a separate, deliberate decision that
    // approving a task was never meant to override.
    private func unlockIfEverythingResolved() {
        guard FamilyStore.child(childId).status == .lockedTasks else { return }
        let stillOutstanding = tasks.contains { $0.state == .pending || $0.state == .review || $0.state == .overdue || $0.state == .bypass }
        guard !stillOutstanding else { return }
        let child = FamilyStore.child(childId)
        child.timeLeft = formatMinutes(child.dailyLimitMin)
        child.timePct = 100
    }

    private func applyEdit(_ updated: ChildTask) {
        let hadDeadline = tasks.first(where: { $0.id == updated.id })?.dueLabel != nil
        TaskEdits.save(updated, clearDueTime: hadDeadline && updated.dueLabel == nil)
        editingTask = nil
    }

    // One step at a time: the edit sheet slides away first, then the task
    // goes, with the next one cutting in as after an approval. Done
    // together, the card vanished under the sheet before it had closed.
    private func applyDelete(_ task: ChildTask) {
        editingTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + TaskEdits.sheetCloseDelay) {
            cut { TaskEdits.delete(task) }
        }
    }

}

// The deck's buttons: they press in under the finger (a little smaller and
// dimmer) the instant they're touched, the way system buttons do, so a tap
// never feels unanswered.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.18, bounce: 0), value: configuration.isPressed)
    }
}

// What the buttons become the moment a task is decided, right where the
// finger was, before the next task slides in: green "Approved" with a
// check, or, sending back, just the orange back-arrow, no words.
private struct DecidedBar: View {
    var approved: Bool
    var space: Namespace.ID
    @State private var shown = false

    var body: some View {
        Group {
            if approved {
                Label("Approved", systemImage: "checkmark")
                    .font(Typography.font(15, weight: .heavy))
                    .symbolEffect(.bounce, value: shown)
            } else {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 20, weight: .bold))
                    .symbolEffect(.bounce.down, value: shown)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity).frame(height: 52)
        .background {
            // Grows out of the Approve button it replaces (same id).
            RoundedRectangle(cornerRadius: 16).fill(approved ? Brand.greenDeep : Color(hex: "EF6C00"))
                .matchedGeometryEffect(id: approved ? "primaryAction" : "secondaryAction", in: space)
        }
        .onAppear { shown = true }
        .accessibilityLabel(approved ? "Approved" : "Sent back for a redo")
    }
}

// One card's worth of the task under review — condensed from the full
// TaskDetailSheet layout to fit a swipeable card instead of a scroll view.
private struct TaskReviewCard: View {
    var task: ChildTask
    var childName: String

    // Which photo the full-screen viewer opens to
    // — set together right before showPhotoViewer flips true, so the
    // viewer never has a stale/mismatched starting page.
    @State private var viewerIndex = 0
    @State private var showPhotoViewer = false

    private var statusMeta: (label: String, tone: Color, bg: Color) {
        switch task.state {
        case .done: return ("Approved", Color(hex: "25924A"), Color(hex: "25924A").opacity(0.10))
        case .bypassed: return ("Skipped", EColor.onSurfaceVariant, EColor.outlineVariant.opacity(0.5))
        case .review: return ("Awaiting your review", Color(hex: "B26A00"), Color(hex: "FFA726").opacity(0.12))
        case .overdue: return ("Overdue · not submitted", EColor.danger, EColor.danger.opacity(0.10))
        case .bypass: return ("Asked to skip", Color(hex: "7C3AED"), Color(hex: "7C3AED").opacity(0.10))
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
                        if !task.photoURLs.isEmpty {
                            SubmissionPhotoGallery(urls: task.photoURLs) { index in
                                viewerIndex = index
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
        // No card of its own: the deck draws one fixed white card and this
        // content slides inside it.
        .fullScreenCover(isPresented: $showPhotoViewer) {
            PhotoGalleryViewer(urls: task.photoURLs, index: $viewerIndex, onClose: { showPhotoViewer = false })
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

// The submission's photos as a square, the way photo apps show a
// multi-photo post: drag sideways on it to move through them, with "2/4" in
// the corner. Swipes that start on the photo page the photos; anywhere else
// on the card they move between tasks. Tapping opens PhotoGalleryViewer at
// the photo showing.
private struct SubmissionPhotoGallery: View {
    var urls: [String]
    var onOpen: (Int) -> Void

    // The first photo only, still: a tap opens them all full screen, where
    // they're paged through. The badge says how many there are.
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemotePhoto(urlString: urls[0], cornerRadius: 0, contentMode: .fill)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if urls.count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "square.on.square").font(.system(size: 10, weight: .bold))
                        Text("\(urls.count)").font(Typography.font(12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture { onOpen(0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(urls.count > 1 ? "\(urls.count) photos. Opens full screen." : "Photo. Opens full screen.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(0) }
    }
}

// The kid's actual submitted photo, loaded from its real R2 download URL —
// used everywhere a submission photo appears (the card's stack, the full-
// screen viewer, its thumbnail strip), so tapping one visibly opens "the
// same photo" bigger rather than a generic gray box. Used to be a hand-
// drawn "photographed homework page" stand-in from before the real photo
// pipeline existed; every task's evidence looked identical then no matter
// what the kid actually turned in.
struct RemotePhoto: View {
    var urlString: String
    var cornerRadius: CGFloat = 12
    var contentMode: ContentMode = .fill

    @State private var uiImage: UIImage?
    @State private var failed = false
    // Bumped to force a fresh load on manual retry — .task(id:) only
    // re-fires when its id actually changes, and urlString alone doesn't
    // change between attempts.
    @State private var retryToken = 0

    // Seeded from the cache, so a photo already downloaded (by the card
    // before, or a previous visit) shows on the first frame, with no
    // placeholder flash each time the card is rebuilt.
    init(urlString: String, cornerRadius: CGFloat = 12, contentMode: ContentMode = .fill) {
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        _uiImage = State(initialValue: URL(string: urlString).flatMap { ImageCache.cached($0) })
    }

    var body: some View {
        Group {
            if let uiImage {
                if contentMode == .fill {
                    // Fill the space the caller gives it, cropped to that
                    // space. A bare .fill image sizes itself past its frame,
                    // so the clip below cut it at its own oversized bounds:
                    // a submission photo spilled over the card's title and
                    // pushed the photo-count bar into its middle.
                    Color.clear
                        .overlay { Image(uiImage: uiImage).resizable().scaledToFill() }
                        .clipped()
                } else {
                    Image(uiImage: uiImage).resizable().aspectRatio(contentMode: contentMode)
                }
            } else {
                Button {
                    guard failed else { return }
                    retryToken += 1
                } label: {
                    // Fit mode sizes to the photo, so the placeholder takes
                    // a phone photo's portrait shape instead of a sliver
                    // that jumps when the image lands.
                    if contentMode == .fit {
                        placeholder(failed: failed).aspectRatio(3.0 / 4.0, contentMode: .fit)
                    } else {
                        placeholder(failed: failed)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!failed)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color(hex: "E4DFCE"), lineWidth: 1))
        .task(id: "\(urlString)#\(retryToken)") {
            failed = false
            guard let url = URL(string: urlString) else {
                print("RemotePhoto: not a valid URL: \(urlString)")
                uiImage = nil
                failed = true
                return
            }
            // Same photo (re-signed URL included): keep showing it.
            if let cached = ImageCache.cached(url) {
                uiImage = cached
                return
            }
            uiImage = nil
            uiImage = await ImageCache.shared.load(url)
            failed = uiImage == nil
        }
    }

    private func placeholder(failed: Bool) -> some View {
        ZStack {
            Color(hex: "FFFDF6")
            VStack(spacing: 4) {
                Image(systemName: failed ? "arrow.clockwise" : "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: "8A8064"))
                if failed {
                    Text("Tap to retry").font(Typography.font(10, weight: .semibold)).foregroundStyle(Color(hex: "8A8064"))
                }
            }
        }
    }
}

// MARK: - Full-screen photo viewer

// Opened by tapping the submission's photos. A segmented bar across the
// top, one segment per photo, shows where you are, Instagram-story style.
// Tap the right side for the next photo and the left for the one before,
// or swipe; swiping down, or going past the last photo, closes it.
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
    var urls: [String]
    @Binding var index: Int
    var onClose: () -> Void

    private var count: Int { urls.count }

    @State private var dragOffset: CGFloat = 0
    @State private var scrollPosition: Int?
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                // A plain HStack, not LazyHStack — a submission is at most
                // a handful of photos, so eagerly building every page costs
                // nothing, and it's what fixes three compounding bugs a
                // *lazy* stack caused once pages started loading real
                // images instead of MockHomeworkPhoto's instant vector
                // drawing: a page recycled mid-swipe could cancel its
                // AsyncImage load and get stuck on the placeholder: reopen
                // after a close could land on a torn-down/not-yet-built
                // page instead of the real photo; and a not-yet-laid-out
                // neighbor could flash a sliver of the wrong image during
                // the transition. All three go away once every page is
                // built (and its image request started) up front.
                HStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                        ZoomablePhotoPage(urlString: url, isZoomed: $isZoomed, onTapSide: step)
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
            // .onChange(of: index) below only fires on a *change* — it
            // never ran on first appearance, which left scrollPosition at
            // its default nil and relied on the ScrollView's own initial
            // layout to happen to land on the right page. That's what made
            // a reopen unreliable: forcing the sync explicitly here means
            // every presentation starts on the actual current index, not
            // on whatever the ScrollView guesses.
            .onAppear { scrollPosition = index }
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

            VStack(spacing: 12) {
                if count > 1 { storyBar }
                HStack {
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
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
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

extension PhotoGalleryViewer {
    // A tap on the right half: next photo (closing after the last). On the
    // left half: the one before.
    func step(forward: Bool) {
        if forward {
            if index < count - 1 { withAnimation(.easeOut(duration: 0.2)) { index += 1 } } else { onClose() }
        } else if index > 0 {
            withAnimation(.easeOut(duration: 0.2)) { index -= 1 }
        }
    }

    // One thin segment per photo: white up to the one on screen, faint
    // after it.
    var storyBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i <= index ? 1 : 0.3))
                    .frame(height: 3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: index)
        .accessibilityElement()
        .accessibilityLabel("Photo \(index + 1) of \(count)")
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
    var urlString: String
    @Binding var isZoomed: Bool
    // A single tap, not zoomed: true for the right half of the page.
    var onTapSide: (_ forward: Bool) -> Void = { _ in }

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
        let photo = RemotePhoto(urlString: urlString, cornerRadius: 20, contentMode: .fit)
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
        GeometryReader { geo in
            Group {
                if isZoomed {
                    photo.simultaneousGesture(magnify.simultaneously(with: pan))
                } else {
                    photo.simultaneousGesture(magnify)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // Double tap zooms; a single tap (once it's clearly not the
            // first of two) moves to the next or previous photo.
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if scale > 1 {
                                resetZoom()
                            } else {
                                scale = 2.5; lastScale = 2.5
                                isZoomed = true
                            }
                        }
                    }
                    .exclusively(before: SpatialTapGesture().onEnded { tap in
                        guard !isZoomed else { return }
                        onTapSide(tap.location.x > geo.size.width / 2)
                    })
            )
        }
    }
}

// Shown on Redo — a quick note the parent sends back explaining what needs
// fixing.
// Same FormShell/FormField shell AddTaskForm uses (Cancel top-left, big
// bold title, full-width Save pill) rather than a bespoke layout, so every
// parent-facing compose sheet in the app reads as one consistent pattern.
private struct RedoComposeSheet: View {
    var childName: String
    var taskTitle: String
    var actionLabel: String
    var onSend: (String) -> Void
    var onCancel: () -> Void

    @State private var note = ""

    private var canSend: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FormShell(
            title: actionLabel,
            onCancel: onCancel,
            onSave: { onSend(note.trimmingCharacters(in: .whitespacesAndNewlines)) },
            canSave: canSend,
            saveLabel: "Send & \(actionLabel.lowercased())"
        ) {
            // Which task is going back, in plain sight under the heading.
            Text(taskTitle)
                .font(Typography.font(18, weight: .bold))
                .foregroundStyle(EColor.onSurface)
                .padding(.bottom, 18)

            FormField(label: "Let \(childName) know why") {
                TextField("e.g. Missed the desk, can you go back and wipe it down?", text: $note, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .lineLimit(3...5)
                    .padding(14)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.bottom, 18)

            Button("\(actionLabel) without a note") { onSend("") }
                .font(Typography.font(13, weight: .semibold))
                .foregroundStyle(EColor.onSurfaceVariant)
                .frame(maxWidth: .infinity)
        }
    }
}

// Every task write, from every screen (Home, the review deck, the calendar,
// chat): put in the phone's database at once, then sent by the outbox.
@MainActor enum TaskEdits {
    /// A new task, under an id made here that the server keeps, so the row
    /// on screen never changes identity. Returns that id.
    @discardableResult
    static func create(childId: String, title: String, instructions: String?, recurrence: String, category: String,
                       dueTime: String?, dueDate: String?, bonusMinutes: Int = 0, createdBy: String = "parent") -> String {
        let id = APIClient.Write.newId()
        let task = ApiTask(
            id: id, title: title, instructions: instructions, recurrence: recurrence, gatesApps: true,
            submissionKind: "none", bucket: "anytime", category: category, dueDate: dueDate, dueTime: dueTime,
            createdAt: CalendarSync.isoString(Date()), bonusMinutes: bonusMinutes, createdBy: createdBy)
        let store = LocalStore.shared
        store.batch {
            store.mirrorTaskSaved(task, childId: childId)
            if CalendarSync.applies(task, on: Date()) {
                store.materializeOccurrence(taskId: id, childId: childId, dueDate: CalendarSync.isoDay(Date()))
            }
        }
        // A new task for today closes the phone again, even if the parent
        // had opened it: the override is cleared here and on the server
        // (routers/tasks.py does the same), so the kid's phone locks at once.
        if CalendarSync.applies(task, on: Date()) {
            let child = FamilyStore.child(childId)
            if child.taskGateOverride {
                child.taskGateOverride = false
                child.saveState(label: "Locking the phone")
            }
        }
        Outbox.send(APIClient.Write.createTask(
            id: id, childId: childId, title: title, instructions: instructions, recurrence: recurrence,
            category: category, submissionKind: "none", dueTime: dueTime, dueDate: dueDate,
            bonusMinutes: bonusMinutes, createdBy: createdBy),
            childId: childId, label: "The new task")
        return id
    }

    /// `clearDueTime`: the deadline was removed, so the server's time is
    /// cleared rather than left as it was.
    static func save(_ updated: ChildTask, clearDueTime: Bool = false) {
        // The time is sent only when the task has a deadline (dueLabel);
        // a task with no time keeps its day in dueDate, at midnight,
        // which isn't a deadline.
        let dueTime = updated.dueLabel == nil ? nil : updated.dueDate.map { format($0, "HH:mm:ss") }
        // A repeating task's date is where the series starts; the date in
        // hand here is only one day it falls on (today, tomorrow, the day
        // open on the calendar). Sending it would move the start and drop
        // the earlier days, so a repeat only ever changes its time.
        let dueDate = updated.repeats == "none" ? updated.dueDate.map { format($0, "yyyy-MM-dd") } : nil
        let clear = clearDueTime && dueTime == nil
        if let saved = LocalStore.shared.cachedTask(id: updated.id), let childId = LocalStore.shared.cachedTaskChild(id: updated.id) {
            LocalStore.shared.mirrorTaskSaved(ApiTask(
                id: saved.id, title: updated.title, instructions: updated.description, recurrence: updated.repeats,
                gatesApps: saved.gatesApps, submissionKind: saved.submissionKind, bucket: saved.bucket,
                category: updated.category, dueDate: dueDate ?? saved.dueDate, dueTime: clear ? nil : (dueTime ?? saved.dueTime),
                createdAt: saved.createdAt, bonusMinutes: saved.bonusMinutes, createdBy: saved.createdBy), childId: childId)
        }
        Outbox.send(APIClient.Write.updateTask(
            taskId: updated.id,
            title: updated.title,
            instructions: updated.description,
            recurrence: updated.repeats,
            category: updated.category,
            submissionKind: updated.photoCount > 0 ? "photo" : "none",
            dueTime: dueTime,
            dueDate: dueDate,
            clearDueTime: clear
        ), label: "Your task edit")
    }

    /// How long a sheet takes to slide away: a delete confirmed in an edit
    /// sheet waits this long, so the task leaves once the sheet has gone,
    /// not underneath it.
    static let sheetCloseDelay: TimeInterval = 0.4

    static func delete(_ task: ChildTask) {
        LocalStore.shared.mirrorTaskDeleted(id: task.id)
        Outbox.send(APIClient.Write.deleteTask(taskId: task.id), label: "Deleting the task")
    }

    static func approve(_ task: ChildTask, childId: String) {
        guard let occurrenceId = task.occurrenceId else { return }
        LocalStore.shared.mirrorOccurrence(id: occurrenceId, status: "approved")
        Outbox.send(APIClient.Write.approveTask(occurrenceId: occurrenceId),
                    occurrenceId: occurrenceId, taskId: task.id, childId: childId, label: "Approving the task")
    }

    /// Sends the task back to the kid, with the note they'll see.
    static func redo(_ task: ChildTask, note: String, childId: String) {
        guard let occurrenceId = task.occurrenceId else { return }
        // What was sent in is discarded (the server deletes it too), so the
        // old photos are gone from this phone at once.
        LocalStore.shared.mirrorOccurrence(id: occurrenceId, status: "rejected", rejectionNote: note, clearPhotos: true)
        Outbox.send(APIClient.Write.rejectTask(occurrenceId: occurrenceId, note: note),
                    occurrenceId: occurrenceId, taskId: task.id, childId: childId, label: "The redo request")
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

// Opened from the "..." button on the review deck's toolbar, the pencil on
// the calendar's task list, and a task on Home's Tomorrow tab — same
// FormShell/FormField shell AddTaskSheet uses, pre-filled from the task,
// plus a Delete action. Like adding a task, it never asks for a date: the
// task stays on its own day (a parent knows tomorrow's task is tomorrow's),
// and More options holds just a deadline time on that day.
struct EditTaskReviewSheet: View {
    var task: ChildTask
    var onSave: (ChildTask) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
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
        // dueLabel is set exactly when the task has a time; dueDate alone
        // can be just its day (an anytime task tomorrow sits at midnight).
        _hasDeadline = State(initialValue: task.dueLabel != nil)
        _deadline = State(initialValue: task.dueLabel != nil ? (task.dueDate ?? Self.parseDueDate(task.dueLabel)) : Date())
        _repeatDays = State(initialValue: task.repeats == "none"
            ? []
            : Set(task.repeats.split(separator: ",").map(String.init)))
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    // The task's own day; never changed here.
    private var day: Date { Calendar.current.startOfDay(for: task.dueDate ?? Date()) }

    var body: some View {
        FormShell(title: "Edit task", onCancel: onCancel, onSave: {
            var updated = task
            updated.title = title.trimmingCharacters(in: .whitespaces)
            updated.description = description
            if hasDeadline {
                let due = TaskDeadlineField.moment(deadline, on: day)
                updated.dueDate = due
                updated.dueLabel = ChildRule.fmtClock(due)
            } else {
                updated.dueDate = task.dueDate.map { Calendar.current.startOfDay(for: $0) }
                updated.dueLabel = nil
            }
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            updated.repeats = repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
            onSave(updated)
        }, canSave: canSave, saveLabel: "Save changes", onDelete: { showDeleteConfirm = true }) {
            FormField(label: "Task name") {
                FormTextField(placeholder: "e.g. Make your bed", text: $title, scrollToTopOnFocus: true)
            }
            RepeatPicker(selectedDays: $repeatDays)
            // Starts expanded when there's already something to show (a
            // deadline, or instructions), so editing doesn't hide the
            // task's own current values behind an extra tap.
            MoreOptions(startOpen: hasDeadline || !description.isEmpty) {
                TaskDeadlineField(hasDeadline: $hasDeadline, time: $deadline, day: day)
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
