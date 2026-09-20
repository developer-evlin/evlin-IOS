import SwiftUI

// Ported from Evlin_Parent_view/index.html's ScreenCalendar — a real Day
// timeline / Month grid / Schedule agenda calendar (not a flat event list),
// with a shared overlap-layout algorithm for same-day events and a detail
// sheet that toggles between view and edit modes.

// Not private any more — ScreenTabletCalendar (the kid-side calendar)
// reuses this same time-grid math and layout algorithm so both sides of
// the app draw the identical timeline from the identical data, just with
// their own chrome around it.
let hourHeight: CGFloat = 56
let startHour = 0
let endHour = 24
let timeColW: CGFloat = 46

func timeToY(_ h: Int, _ m: Int = 0) -> CGFloat {
    CGFloat(h - startHour) * hourHeight + CGFloat(m) / 60 * hourHeight
}

func evTop(_ start: String) -> CGFloat {
    let mins = CalendarData.minutesSinceMidnight(start)
    return timeToY(mins / 60, mins % 60)
}

func fmtHour(_ h: Int) -> String {
    if h == 0 || h == 24 { return "" }
    if h == 12 { return "12 PM" }
    return h < 12 ? "\(h) AM" : "\(h - 12) PM"
}

struct LaidOutEvent: Identifiable {
    var id: UUID
    var dayEvent: CalDayEvent
    var top: CGFloat
    var height: CGFloat
    var col: Int
    var numCols: Int
    // Within this one lane, events that strictly overlap in time (not
    // merely touch at an endpoint) split the lane's own width side by
    // side, same as Google/Apple Calendar's day view — see splitOverlaps.
    // 0/1 (the defaults) mean "has this lane's full width to itself."
    var laneCol: Int = 0
    var laneNumCols: Int = 1
}

// Every person gets a permanently-assigned lane spanning the whole day, in
// the same left-to-right order as the avatar row above the timeline — not
// just splitting width when two people happen to overlap in time. That used
// to mean a non-overlapping event (the common case: most of a family's
// events don't collide) rendered full-width, with nothing to visually tie
// it to "this is your child's lane" the way the header row implies. Now your child's
// events always sit under your child's avatar, whether or not anyone else (the
// parent's own "family" events, or another child if Settings adds one) has
// something scheduled at the same time.
//
// That lane is still just one column wide, though — if your child himself has
// two things at once (a task due mid-event, say), they used to draw
// directly on top of each other. splitOverlaps below runs a second,
// per-lane pass to give those their own side-by-side sub-columns.
func layoutDayEvents(_ events: [CalDayEvent], lanes: [FamilyPerson]) -> [LaidOutEvent] {
    let numCols = max(lanes.count, 1)
    let items: [LaidOutEvent] = events.compactMap { de -> LaidOutEvent? in
        // Anytime tasks belong to the day, not to a moment — they live in
        // the ANYTIME zone, never on this grid.
        guard !de.event.isAnytime else { return nil }
        // Matched by id, never by array position — lanes and the event
        // list are built from two different filtered views of
        // CalendarData.people, so an index-based pairing would silently
        // drift the moment either one dropped or reordered an entry.
        guard let colIndex = lanes.firstIndex(where: { $0.id == de.event.personId }) else { return nil }
        let start = evTop(de.event.start)
        let end = max(evTop(de.event.end), start + 1)
        return LaidOutEvent(id: de.id, dayEvent: de, top: start, height: end - start, col: colIndex, numCols: numCols)
    }
    // Overlap is scoped to one lane at a time — two different people's
    // events never fight over a sub-column just because they happen to
    // land at the same time.
    let byLane = Dictionary(grouping: items, by: \.col)
    return byLane.values.flatMap(splitOverlaps)
}

// The standard day-view collision algorithm (Google/Apple Calendar): sort
// by start time, group into clusters wherever consecutive events actually
// intersect (a strict interval test — one ending exactly when the next
// starts is NOT an overlap), then within each cluster greedily pack events
// into the first sub-column whose last occupant has already ended, adding
// a new sub-column only when none is free. Every event in a cluster ends
// up with the same laneNumCols (that cluster's column count); an event
// with no overlap at all is its own cluster of one, so it keeps the
// lane's full width.
private func splitOverlaps(_ items: [LaidOutEvent]) -> [LaidOutEvent] {
    guard items.count > 1 else { return items }
    let order = items.indices.sorted {
        items[$0].top != items[$1].top ? items[$0].top < items[$1].top : items[$0].height > items[$1].height
    }

    var result = items
    func flush(_ clusterIndices: [Int]) {
        guard clusterIndices.count > 1 else { return }
        var columnEnds: [CGFloat] = []
        for i in clusterIndices {
            let ev = items[i]
            if let freeCol = columnEnds.firstIndex(where: { $0 <= ev.top }) {
                columnEnds[freeCol] = ev.top + ev.height
                result[i].laneCol = freeCol
            } else {
                result[i].laneCol = columnEnds.count
                columnEnds.append(ev.top + ev.height)
            }
        }
        for i in clusterIndices { result[i].laneNumCols = columnEnds.count }
    }

    var cluster: [Int] = [order[0]]
    var clusterEnd = items[order[0]].top + items[order[0]].height
    for idx in order.dropFirst() {
        let ev = items[idx]
        if ev.top >= clusterEnd {
            flush(cluster)
            cluster = [idx]
            clusterEnd = ev.top + ev.height
        } else {
            cluster.append(idx)
            clusterEnd = max(clusterEnd, ev.top + ev.height)
        }
    }
    flush(cluster)
    return result
}

// A deadline isn't an interval — nothing happens between now and the due
// moment — so it never needed a rectangle competing for lane width the way
// an event does. Every timed task sharing a child and a due minute is one
// unit on screen: three tasks due at 6PM for the same kid is one marker,
// not three slivers fighting for space.
struct TaskDueGroup: Identifiable {
    var personId: String
    var start: String
    var tasks: [CalDayEvent]
    // Keyed by the same minute value grouping used, not the raw display
    // string — two tasks due at the same moment must produce the same id
    // even if their `start` strings happen to differ in formatting.
    var id: String { "\(personId)|\(CalendarData.minutesSinceMidnight(start))" }
}

// Grouped by child + due *minute* (not the raw start string) — two tasks
// whose start strings are formatted differently but land on the same
// minute must still collapse into one marker. This is the only thing that
// makes two due-at-once tasks in the same lane impossible to render as
// separate, overlapping pills.
func groupDueTasks(_ events: [CalDayEvent]) -> [TaskDueGroup] {
    var order: [String] = []
    var buckets: [String: TaskDueGroup] = [:]
    for de in events where de.event.category == "Task" && !de.event.isAnytime {
        let minute = CalendarData.minutesSinceMidnight(de.event.start)
        let key = "\(de.event.personId)|\(minute)"
        if buckets[key] == nil {
            buckets[key] = TaskDueGroup(personId: de.event.personId, start: de.event.start, tasks: [])
            order.append(key)
        }
        buckets[key]?.tasks.append(de)
    }
    return order.compactMap { buckets[$0] }
}

struct ScreenCalendar: View {
    @State private var selectedDay = CalendarData.dataDay
    @State private var showDatePicker = false
    // Backend-backed: CalendarData.eventsByDay is rebuilt by AppSync; edits
    // below update this copy right away (so the UI feels instant), save to
    // the backend, and the next sync replaces it with the saved rows.
    @State private var eventsByDay: [Int: [CalEvent]] = CalendarData.eventsByDay
    @State private var saveFailed = false
    @State private var activeDayEvent: CalDayEvent?
    // Every timed task due at the same moment for the same kid opens as
    // one group sheet, not a per-task detail — see TaskDueGroupSheet.
    @State private var activeTaskGroup: TaskDueGroup?
    @State private var showAddEvent = false
    // Tapping a task on the calendar doesn't open a small in-place detail
    // sheet any more. When it has a real counterpart (linkedTaskId —
    // every seeded demo task), it goes *straight* to TaskReviewDeckView
    // for that exact task — no detour through the kid's profile first,
    // so "Close" there returns right back to the calendar, not to a home
    // page the parent never asked to see. Only a task with no real
    // counterpart (one added ad-hoc via "+") falls back to opening the
    // kid's own profile, same as tapping a task notification does (see
    // ScreenHome) — there's nothing to review, so the profile is the
    // closest honest landing spot.
    @State private var reviewTasks: [ChildTask] = []
    @State private var reviewChildName = ""
    // Needed to sync an approval back into eventsByDay on dismiss (see
    // syncReviewedTasks) — ChildTask ids aren't globally unique, only
    // unique per child, so matching a review back to its CalEvent needs
    // both.
    @State private var reviewPersonId = ""
    @State private var reviewStartIndex = 0
    @State private var showTaskReview = false
    @State private var openChildId: String?
    // Tapping an avatar in the lane header dims them out and hides their
    // whole column from the grid/ANYTIME row — a quick "just show me
    // your child" filter, not a destructive action. Starts with everyone on,
    // the parent included.
    @State private var activeLaneIds: Set<String> = []

    // The parent gets a real lane too, same as every kid — their own
    // events (a work call, anything personal) belong somewhere, and
    // hiding their lane by default read as "the parent isn't really part
    // of this calendar." Family-wide events (Family Lunch, Family Dinner)
    // still aren't any one lane's — those render as their own full-width
    // blocks via CalendarData.everyone, not by occupying this lane list.
    private var lanePeople: [FamilyPerson] {
        var people = [FamilyPerson(id: "family", name: "Parent", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))]
        for child in FamilyStore.children {
            people.append(FamilyPerson(id: child.id, name: child.name, color: child.color, bg: child.color.opacity(0.15)))
        }
        return people
    }

    private func expandedEvents(for day: Int) -> [CalDayEvent] {
        CalendarData.expandedEvents(for: day, in: eventsByDay)
    }

    // linkedTaskId is a direct, deterministic pointer to the real
    // ChildTask — set on every seeded demo task. Presenting
    // TaskReviewDeckView ourselves (instead of opening ScreenProfile and
    // letting *its* init trigger the same cover) is what skips the kid's
    // profile entirely — there's no other way to land on that view
    // without a profile instance existing somewhere underneath it. Only a
    // task with no real counterpart (one added ad-hoc via "+") falls back
    // to opening the kid's own profile, same as tapping a task
    // notification does (see ScreenHome) — there's nothing to review, so
    // the profile is the closest honest landing spot. Shared by both a
    // direct task tap and a due-marker group of exactly one.
    private func openTaskDetail(_ de: CalDayEvent) {
        let tasks = TaskStore.tasks(for: de.event.personId)
        if let linkedId = de.event.linkedTaskId,
           let idx = tasks.firstIndex(where: { $0.id == linkedId }) {
            reviewTasks = tasks
            reviewChildName = CalendarData.person(de.event.personId).name
            reviewPersonId = de.event.personId
            reviewStartIndex = idx
            showTaskReview = true
        } else {
            openChildId = de.event.personId
        }
    }

    // TaskReviewDeckView mutates its own ChildTask/TaskStore-backed array —
    // a different, disconnected mock store from this screen's own
    // eventsByDay/CalEvent. Approving a task there would otherwise leave
    // its deadline marker on the grid silently showing the old, no longer
    // true status. Called once review closes, so every task touched during
    // that session gets its calendar-side counterpart caught up.
    private func syncReviewedTasks(_ tasks: [ChildTask], personId: String) {
        for task in tasks where task.state == .done {
            for day in eventsByDay.keys {
                if let i = eventsByDay[day]?.firstIndex(where: { $0.personId == personId && $0.linkedTaskId == task.id }) {
                    eventsByDay[day]?[i].taskState = .done
                }
            }
        }
    }

    // MARK: Backend saves

    private func reloadFromStore() { eventsByDay = CalendarData.eventsByDay }

    private static func dayString(_ day: Int) -> String {
        String(format: "%04d-%02d-%02d", CalendarData.dataYear, CalendarData.dataMonth, day)
    }

    private static func dueTimeString(_ clock: String) -> String {
        let m = CalendarData.minutesSinceMidnight(clock)
        return String(format: "%02d:%02d:00", m / 60, m % 60)
    }

    /// personId "family" is the parent's own lane, "everyone" is family-wide;
    /// neither is a child row, so both are stored with no child_id and told
    /// apart by `source`.
    private static func eventScope(_ personId: String) -> (childId: String?, source: String) {
        if FamilyStore.children.contains(where: { $0.id == personId }) { return (personId, "manual") }
        return (nil, personId == "family" ? "parent" : "everyone")
    }

    private static func eventDates(_ ev: CalEvent, day: Int) -> (Date, Date) {
        let start = CalendarData.date(day: day, minutes: CalendarData.minutesSinceMidnight(ev.start))
        var end = CalendarData.date(day: day, minutes: CalendarData.minutesSinceMidnight(ev.end))
        if end < start { end = start.addingTimeInterval(3600) }
        return (start, end)
    }

    private func save(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                await AppSync.shared.syncBackendData()
            } catch {
                print("Calendar save failed: \(error)")
                reloadFromStore()
                saveFailed = true
            }
        }
    }

    private func createItem(_ ev: CalEvent, day: Int) {
        eventsByDay[day, default: []].append(ev)
        save {
            if ev.category == "Task" {
                // A task belongs to a real child; the "Parent" lane can't own one.
                guard FamilyStore.children.contains(where: { $0.id == ev.personId }) else { throw URLError(.badURL) }
                _ = try await APIClient.shared.createTask(
                    childId: ev.personId, title: ev.title,
                    instructions: ev.note.isEmpty ? nil : ev.note,
                    recurrence: ev.repeats, bucket: ev.isAnytime ? "anytime" : "timed",
                    submissionKind: "button",
                    dueTime: ev.isAnytime ? nil : Self.dueTimeString(ev.start),
                    dueDate: Self.dayString(day)
                )
            } else {
                let scope = Self.eventScope(ev.personId)
                let (start, end) = Self.eventDates(ev, day: day)
                _ = try await APIClient.shared.createEvent(
                    childId: scope.childId, title: ev.title, start: start, end: end,
                    category: ev.category, note: ev.note, location: ev.location,
                    recurrence: ev.repeats, source: scope.source
                )
            }
        }
    }

    private func updateItem(_ updated: CalEvent, originDay: Int) {
        if let i = eventsByDay[originDay]?.firstIndex(where: { $0.id == updated.id }) {
            eventsByDay[originDay]?[i] = updated
        }
        guard let remoteId = updated.remoteId else { return }
        save {
            let scope = Self.eventScope(updated.personId)
            let (start, end) = Self.eventDates(updated, day: originDay)
            try await APIClient.shared.updateEvent(
                eventId: remoteId, childId: scope.childId, title: updated.title, start: start, end: end,
                category: updated.category, note: updated.note, location: updated.location,
                recurrence: updated.repeats, source: scope.source
            )
        }
    }

    private func deleteItem(_ ev: CalEvent, originDay: Int) {
        eventsByDay[originDay]?.removeAll { $0.id == ev.id }
        guard let remoteId = ev.remoteId else { return }
        save { try await APIClient.shared.deleteEvent(eventId: remoteId) }
    }

    var body: some View {
        NavigationStack {
            DayTimelineView(
                selectedDay: $selectedDay,
                visiblePeople: lanePeople,
                activeLaneIds: $activeLaneIds,
                events: expandedEvents(for: selectedDay),
                onSelect: { de in
                    if de.event.category == "Task" {
                        openTaskDetail(de)
                    } else {
                        activeDayEvent = de
                    }
                },
                // A group of exactly one is really just that one task — go
                // straight to its detail the same way tapping any other
                // single task does, rather than opening a one-row sheet
                // that only exists to let a parent pick between rows.
                onSelectGroup: { group in
                    if group.tasks.count == 1 {
                        openTaskDetail(group.tasks[0])
                    } else {
                        activeTaskGroup = group
                    }
                },
                onOpenDatePicker: { showDatePicker = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            // safeAreaInset reserves real layout space for the FAB, so the
            // last row of the scrolling grid can never end up rendered
            // underneath it — the FAB sits just above the tab bar's own
            // safe-area inset, not floating in the gap above it.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button { showAddEvent = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Brand.ink)
                            .clipShape(Circle())
                            .shadow(color: Brand.ink.opacity(0.35), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 16)
            }
            .navigationBarHidden(true)
        }
        .sheet(item: $activeDayEvent) { de in
            EventDetailSheet(dayEvent: de, onSave: { updated in
                updateItem(updated, originDay: de.originDay)
                activeDayEvent = nil
            }, onDelete: {
                deleteItem(de.event, originDay: de.originDay)
                activeDayEvent = nil
            }, onClose: { activeDayEvent = nil })
        }
        .sheet(item: $activeTaskGroup) { group in
            TaskDueGroupSheet(
                group: group,
                onApprove: { de in
                    if let i = eventsByDay[de.originDay]?.firstIndex(where: { $0.id == de.event.id }) {
                        eventsByDay[de.originDay]?[i].taskState = .done
                    }
                },
                onClose: { activeTaskGroup = nil }
            )
        }
        // fullScreenCover, not .sheet — this is a real screen (that kid's
        // own profile), not a modal detail card. Matches ScreenHome's own
        // task-notification deep link exactly.
        .fullScreenCover(item: Binding(get: { openChildId.map { IdentifiedString(value: $0) } }, set: { openChildId = $0?.value })) { wrapped in
            NavigationStack {
                ScreenProfile(childId: wrapped.value, onBack: { openChildId = nil })
            }
        }
        // The direct jump: no ScreenProfile instance involved at all, so
        // dismissing this lands right back on the calendar.
        .fullScreenCover(isPresented: $showTaskReview) {
            TaskReviewDeckView(tasks: $reviewTasks, childName: reviewChildName, childId: reviewPersonId, startIndex: reviewStartIndex, onDismiss: {
                syncReviewedTasks(reviewTasks, personId: reviewPersonId)
                showTaskReview = false
            })
        }
        .sheet(isPresented: $showAddEvent) {
            AddCalendarSheet(currentDay: selectedDay, onCreate: { ev, day in
                createItem(ev, day: day)
                showAddEvent = false
            }, onCancel: { showAddEvent = false })
        }
        .onChange(of: SyncState.shared.version) { _, _ in reloadFromStore() }
        .onAppear { reloadFromStore() }
        .alert("Couldn't save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That change wasn't saved. Check your connection (and that the task is for a child) and try again.")
        }
        .sheet(isPresented: $showDatePicker) {
            MonthPickerSheet(selectedDay: selectedDay, eventsByDay: eventsByDay, onPickDay: { d in
                selectedDay = d
                showDatePicker = false
            })
            .presentationDetents([.height(480)])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Day timeline

// A fixed column, not a single scrolling block: the date bar, family-events
// strip, lane header, and ANYTIME row are ordinary VStack siblings with no
// ScrollView of their own — they take their natural height and stay put.
// Only the hour grid scrolls, in the one ScrollView at the bottom, sized to
// fill whatever height those fixed sections don't use. Wrapping the *whole*
// column in a GeometryReader (to get one shared width for the grid math)
// starved that ScrollView of a determinate height and collapsed it to
// nothing — the GeometryReader here stays scoped to just the grid's own
// ScrollView content, exactly where the original single-region version had
// it, so the fixed sections above never depend on it.
private struct DayTimelineView: View {
    @Binding var selectedDay: Int
    var visiblePeople: [FamilyPerson]
    @Binding var activeLaneIds: Set<String>
    var events: [CalDayEvent]
    var onSelect: (CalDayEvent) -> Void
    var onSelectGroup: (TaskDueGroup) -> Void
    var onOpenDatePicker: () -> Void

    // Only the lanes still toggled on — dimmed-out people disappear from
    // the grid and ANYTIME row entirely, but stay in the header (dimmed)
    // so tapping them again brings them back.
    private var activePeople: [FamilyPerson] { visiblePeople.filter { activeLaneIds.contains($0.id) } }

    private func toggleLane(_ id: String) {
        if activeLaneIds.contains(id) {
            // Never let the last visible lane be switched off — there'd be
            // nothing left to tap back on.
            if activeLaneIds.count > 1 { activeLaneIds.remove(id) }
        } else {
            activeLaneIds.insert(id)
        }
    }

    private var filteredEvents: [CalDayEvent] {
        let ids = Set(activePeople.map(\.id))
        return events.filter { ids.contains($0.event.personId) }
    }

    private var familyEvents: [CalDayEvent] {
        events.filter { $0.event.personId == CalendarData.everyone.id }.sorted { evTop($0.event.start) < evTop($1.event.start) }
    }

    private func anytimeTasks(for personId: String) -> [CalDayEvent] {
        filteredEvents.filter { $0.event.personId == personId && $0.event.isAnytime }
    }

    private var hasAnytimeTasks: Bool {
        activePeople.contains { !anytimeTasks(for: $0.id).isEmpty }
    }

    // The full day, always — midnight to midnight, 24 rows of hourHeight
    // each. No dynamic "7 AM–9 PM unless something needs more" window: a
    // grid that stops early reads as "the day ends here," and a family's
    // actual evening (dinner, story time, bedtime tasks) routinely runs
    // past whatever a shortened default would have picked anyway.
    private var rangeStartHour: Int { startHour }
    private var rangeEndHour: Int { endHour }
    private var rangeStartY: CGFloat { timeToY(rangeStartHour) }
    // Labels/dividers draw one line per boundary, 0 through 24 inclusive —
    // the trailing 24 is just the closing line at midnight (fmtHour(24)
    // prints nothing) and draws no row of its own.
    private var hours: [Int] { Array(rangeStartHour...rangeEndHour) }
    // The ruler ScrollViewReader anchors against is the 24 actual hour
    // *rows* (0:00–0:59 through 23:00–23:59) — one shorter than `hours`
    // above on purpose. Including a 25th "hour-24" block here made the
    // ruler 24×hourHeight taller than the grid's real content height, and
    // since nothing in the app ever scrolls to hour 24 (Calendar's own
    // .hour component never returns 24), dropping it costs nothing.
    private var hourRows: [Int] { Array(rangeStartHour..<rangeEndHour) }

    // The real clock's hour, not the mock day's — clamped to the rendered
    // range so scrolling to it never lands outside the grid on a day whose
    // range doesn't cover the current hour.
    private var nowHour: Int {
        min(max(Calendar.current.component(.hour, from: Date()), rangeStartHour), rangeEndHour)
    }

    // Minute-precision now, for the red "current time" line — distinct
    // from nowHour above, which only needs hour precision to pick a scroll
    // target. "Today" here means the app's fixed mock day, not the real
    // calendar date, so the line only ever shows while that day is open.
    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private var showNowLine: Bool {
        selectedDay == CalendarData.dataDay
            && nowMinutes >= rangeStartHour * 60 && nowMinutes <= rangeEndHour * 60
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        // One tick's defer — .scrollTo on the same frame the content first
        // lays out can resolve against the pre-layout geometry and land
        // short.
        DispatchQueue.main.async {
            // anchor: .top, not a fractional UnitPoint — a y:0.33 anchor
            // asks the scroll view to place `now` a third of the way down
            // the viewport, which past a certain hour needs more content
            // *above* now than the day actually has left below the fold
            // to balance it. ScrollView has no headroom to overscroll
            // into, so it was clamping in a way that left earlier blocks
            // (Family Dinner, 6 PM) rendered above the visible top edge
            // with no way to scroll up into them. Anchoring flush to the
            // top of the target hour is always satisfiable.
            //
            // One hour earlier than `now`, not `now` itself — a deadline
            // marker's pill sits *above* its own due line (see
            // taskDueMarker), so a task due in the same hour as "now"
            // would otherwise have its pill scrolled just above the very
            // top edge the moment the calendar opens. A full hour of
            // headroom is more than enough for that pill to still land
            // inside the visible area.
            let anchorHour = max(rangeStartHour, nowHour - 1)
            withAnimation(nil) { proxy.scrollTo("hour-\(anchorHour)", anchor: .top) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dateBar
            Divider()

            laneHeader
                .frame(height: 56)
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            if hasAnytimeTasks {
                anytimeZone
                Divider()
            }

            // Read the real bottom safe area (tab bar + home indicator,
            // plus whatever the outer FAB safeAreaInset adds on top of
            // that) here, before entering the ScrollView — content inside
            // a ScrollView has no safe-area edges of its own to measure.
            GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        let trackWidth = geo.size.width - timeColW
                        let gridHeight = timeToY(rangeEndHour) - rangeStartY
                        // Tasks never enter the block/overlap pipeline any
                        // more — a deadline has no duration to lay out, so
                        // only real events (category != "Task") compete for
                        // lane width here.
                        let laidOut = layoutDayEvents(filteredEvents.filter { $0.event.category != "Task" }, lanes: activePeople)
                        let dueGroups = groupDueTasks(filteredEvents)
                        ZStack(alignment: .topLeading) {
                            // A normal-flow ruler, invisible, purely so
                            // ScrollViewReader has a real *layout* position
                            // to resolve — everything else in this ZStack is
                            // placed with .offset(), which moves a view
                            // visually without moving the layout frame
                            // .scrollTo actually reads, so none of those
                            // could ever be a reliable scroll target. Exactly
                            // 24 rows (hourRows), not 25 — see hourRows' own
                            // doc comment.
                            VStack(spacing: 0) {
                                ForEach(hourRows, id: \.self) { h in
                                    Color.clear.frame(height: hourHeight).id("hour-\(h)")
                                }
                            }

                            ForEach(hours, id: \.self) { h in
                                HStack(spacing: 0) {
                                    Text(fmtHour(h))
                                        .font(Typography.font(10, weight: .semibold))
                                        .foregroundStyle(EColor.onSurfaceVariant)
                                        .frame(width: timeColW, alignment: .trailing)
                                        .padding(.trailing, 8)
                                    Rectangle().fill(EColor.outlineVariant).frame(maxWidth: .infinity).frame(height: 0.5)
                                }
                                .frame(width: geo.size.width, alignment: .leading)
                                .offset(y: timeToY(h) - 6 - rangeStartY)
                            }

                            // Vertical rules between lanes — a lane's column
                            // is otherwise only implied by where its blocks
                            // happen to sit.
                            if activePeople.count > 1 {
                                ForEach(1..<activePeople.count, id: \.self) { i in
                                    Rectangle().fill(EColor.outlineVariant).frame(width: 0.5, height: gridHeight)
                                        .offset(x: timeColW + trackWidth * CGFloat(i) / CGFloat(activePeople.count))
                                }
                            }

                            // Family events span the full width, behind
                            // each kid's own blocks — they're everyone's,
                            // not any one lane's.
                            ForEach(familyEvents) { de in
                                familyBlock(de, trackWidth: trackWidth)
                            }

                            ForEach(laidOut) { item in
                                eventBlock(item, trackWidth: trackWidth)
                            }

                            // Deadlines: a 2pt rule marking the exact
                            // moment, a pill above it to tap — drawn last
                            // (and given a high zIndex) so a marker can sit
                            // on top of whatever event block happens to run
                            // through that same hour without needing to
                            // fight it for width.
                            ForEach(dueGroups) { group in
                                taskDueMarker(group, trackWidth: trackWidth)
                            }

                            if showNowLine {
                                Rectangle().fill(Color(hex: "E0483F")).frame(width: trackWidth, height: 2)
                                    .offset(x: timeColW, y: timeToY(nowMinutes / 60, nowMinutes % 60) - rangeStartY - 1)
                                    .zIndex(100)
                            }
                        }
                    }
                    // Exactly 24×hourHeight — the grid's own content
                    // height, no added buffer. The scroll content's total
                    // height is this plus the safe-area padding below,
                    // and nothing else.
                    .frame(height: timeToY(rangeEndHour) - rangeStartY)
                    .padding(.bottom, outerGeo.safeAreaInsets.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToNow(proxy) }
                .onChange(of: selectedDay) { _, _ in scrollToNow(proxy) }
            }
            }
        }
    }

    private var dateBar: some View {
        HStack {
            Button { selectedDay = max(1, selectedDay - 1) } label: { navCircle("chevron.left") }
            Spacer()
            Button(action: onOpenDatePicker) {
                VStack(spacing: 2) {
                    Text("\(CalendarData.dayNames[selectedDay] ?? ""), \(CalendarData.monthShort) \(selectedDay)")
                        .font(Typography.font(17, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                    // Always the tap hint, even on today — "TODAY" alone
                    // told a parent what day it was but not that the row
                    // itself is a button, which is exactly what got missed.
                    Text("TAP TO CHANGE DATE")
                        .font(Typography.font(10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(selectedDay == CalendarData.dataDay ? EColor.secondary : EColor.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { selectedDay = min(CalendarData.daysInDataMonth, selectedDay + 1) } label: { navCircle("chevron.right") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func navCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(EColor.primary)
            .frame(width: 34, height: 34)
            .background(EColor.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // A translucent band behind every lane's own content, not an opaque
    // block in front of it — it's everyone's, so it must never be able to
    // hide a kid's own event or a deadline marker running through the same
    // hour. The solid left rule (plus the tint itself) is what still reads
    // "this is a family thing" at a glance, without covering anything.
    private func familyBlock(_ de: CalDayEvent, trackWidth: CGFloat) -> some View {
        let ev = de.event
        let p = CalendarData.everyone
        let top = evTop(ev.start)
        let height = max(evTop(ev.end) - top, 28)
        return Button { onSelect(de) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.title)
                    .font(Typography.font(11, weight: .heavy))
                    .lineLimit(1)
                if height > 34 {
                    Text("\(ev.start) \u{2013} \(ev.end)")
                        .font(Typography.font(9.5, weight: .semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(p.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: max(trackWidth - 4, 24), height: height, alignment: .topLeading)
            .background(p.color.opacity(0.14))
            .overlay(alignment: .leading) { Rectangle().fill(p.color).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + 2, y: top - rangeStartY + 1)
        .zIndex(0)
    }

    // Every person is always listed here — tapping one dims it and pulls
    // its whole column out of the grid/ANYTIME row below, tapping again
    // brings it back. Unlike the grid, this row never loses a person.
    private var laneHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColW)
            ForEach(visiblePeople) { p in
                let isActive = activeLaneIds.contains(p.id)
                Button { toggleLane(p.id) } label: {
                    VStack(spacing: 3) {
                        Circle().fill(p.color).frame(width: 32, height: 32)
                            .overlay(Text(String(p.name.prefix(1))).font(Typography.font(13, weight: .bold)).foregroundStyle(.white))
                        Text(p.name).font(Typography.font(9.5, weight: .semibold)).foregroundStyle(EColor.onSurface)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(isActive ? 1 : 0.28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var anytimeZone: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("ANY\nTIME")
                .font(Typography.font(9, weight: .bold))
                .tracking(0.4)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(EColor.onSurfaceVariant)
                .frame(width: timeColW, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 2)
            ForEach(activePeople) { p in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(anytimeTasks(for: p.id)) { de in
                        anytimeChip(de)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // Strikethrough is the only status signal now (done) — no icon.
    private func anytimeChip(_ de: CalDayEvent) -> some View {
        let ev = de.event
        let p = CalendarData.person(ev.personId)
        return Button { onSelect(de) } label: {
            Text(ev.title)
                .font(Typography.font(11.5, weight: .semibold))
                .strikethrough(ev.taskState == .done)
                .lineLimit(1)
                .foregroundStyle(p.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.bg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // Events only now — tasks never enter this pipeline, so there's
    // nothing left to tell apart by shape; every block here just happens,
    // at a time.
    private func eventBlock(_ item: LaidOutEvent, trackWidth: CGFloat) -> some View {
        let ev = item.dayEvent.event
        let p = CalendarData.person(ev.personId)
        let laneWidth = trackWidth / CGFloat(item.numCols)
        let laneLeft = laneWidth * CGFloat(item.col)
        // Sub-split within this one lane wherever splitOverlaps found a
        // real collision — 1/1 (the common case) leaves this exactly the
        // lane's own full width, unchanged from before.
        let subWidth = laneWidth / CGFloat(item.laneNumCols)
        let subLeft = subWidth * CGFloat(item.laneCol)
        let w = max(subWidth - 6, 24)
        return Button { onSelect(item.dayEvent) } label: {
            Text(ev.title)
                .font(Typography.font(11, weight: .heavy))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.top, item.height > 40 ? 7 : 4)
                .frame(width: w, height: item.height, alignment: .topLeading)
                .background(p.color)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + laneLeft + subLeft + 3, y: item.top - rangeStartY)
        .zIndex(1)
    }

    // MARK: - Deadline markers — a due moment has no duration, so it's a
    // full-lane-width rule (marks exactly when, top = dueY) with a pill
    // flush against its top edge (pill bottom = dueY, so the two sit as
    // one shape, not a button floating over an unrelated underline). Both
    // are independently positioned against the lane column itself — never
    // nested inside an event's own view — and drawn at a zIndex well above
    // every event and the family band, so a marker can sit on top of
    // whatever's running through that hour without needing to fight it
    // for width.
    private static let dueMarkerHeight: CGFloat = 24
    private static let dueMarkerInset: CGFloat = 2

    private func taskDueMarker(_ group: TaskDueGroup, trackWidth: CGFloat) -> some View {
        Group {
            if let colIndex = activePeople.firstIndex(where: { $0.id == group.personId }) {
                let laneWidth = trackWidth / CGFloat(max(activePeople.count, 1))
                let laneLeft = laneWidth * CGFloat(colIndex)
                let pillWidth = max(laneWidth - Self.dueMarkerInset * 2, 32)
                let dueY = evTop(group.start) - rangeStartY

                // The rule spans the full lane, same width as the pill
                // sitting on it — a moment crossing the whole column, not
                // a short tick under a button.
                Rectangle()
                    .fill(dueGroupTint(group))
                    .frame(width: pillWidth, height: 2)
                    .offset(x: timeColW + laneLeft + Self.dueMarkerInset, y: dueY)
                    .zIndex(50)

                Button { onSelectGroup(group) } label: {
                    dueGroupPill(group, width: pillWidth)
                }
                .buttonStyle(.plain)
                .offset(x: timeColW + laneLeft + Self.dueMarkerInset, y: dueY - Self.dueMarkerHeight)
                .zIndex(51)
            }
        }
    }

    // Amber if anything in the group is awaiting the parent's review,
    // struck-through green once every task in it is approved, otherwise
    // the child's own colour — the same priority the pill's border and
    // the sheet's own accents use, so the grid and the sheet never
    // disagree about how urgent a group is.
    private func dueGroupTint(_ group: TaskDueGroup) -> Color {
        if group.tasks.contains(where: { $0.event.taskState == .submitted }) {
            return Color(hex: "B26A00")
        }
        if group.tasks.allSatisfy({ $0.event.taskState == .done }) {
            return Color(hex: "25924A")
        }
        return CalendarData.person(group.personId).color
    }

    // A lock glyph always leads — it's what says "this is a deadline," not
    // the colour alone. A single task always shows its own name (tapping
    // it goes straight there, same as any other task, so the name is what
    // a parent actually needs to recognize it); a real group — more than
    // one task landing on the same moment — shows a count instead, since
    // no single name would be honest about what's in it.
    private func dueGroupPill(_ group: TaskDueGroup, width: CGFloat) -> some View {
        let tint = dueGroupTint(group)
        let allDone = group.tasks.allSatisfy { $0.event.taskState == .done }

        return HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            if group.tasks.count == 1 {
                Text(group.tasks[0].event.title)
                    .font(Typography.font(11, weight: .heavy))
                    .strikethrough(allDone)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("\(group.tasks.count) tasks")
                    .font(Typography.font(11, weight: .heavy))
                    .strikethrough(allDone)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(width: width, height: Self.dueMarkerHeight, alignment: .leading)
        // Approved gets a tinted fill, not plain white — the same shaded,
        // settled look "done" already reads as everywhere else in this
        // app (the ANYTIME chips, TaskReviewDeck's own Approved status),
        // so a marker doesn't keep looking exactly as urgent once it's
        // actually taken care of.
        .background(allDone ? tint.opacity(0.12) : Color.white)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(tint, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Month picker sheet

// Ported from the native Reminders/Calendar "tap to change date" pattern:
// tapping the day header opens this bottom sheet with a plain Sunday-first
// month grid; picking a day selects it and dismisses the sheet. Browsing
// isn't limited to the one month the mock data lives in — arrows and a
// swipe both page to the next/previous month — but since eventsByDay/
// dayNames only model that single seeded month (CalendarData.dataMonth/
// dataYear), a day is only actually pickable there; other months are
// look-but-don't-touch, same idea as the existing `d == nil` blank cells.
private struct MonthPickerSheet: View {
    var selectedDay: Int
    var eventsByDay: [Int: [CalEvent]]
    var onPickDay: (Int) -> Void

    @State private var displayedYear = CalendarData.dataYear
    @State private var displayedMonth = CalendarData.dataMonth

    private var cells: [Int?] { CalendarData.monthGrid(year: displayedYear, month: displayedMonth) }
    private var isDataMonth: Bool { displayedYear == CalendarData.dataYear && displayedMonth == CalendarData.dataMonth }

    // Up to four dots under a day, one per person with something on it —
    // a quick-glance density hint while browsing, same idea as the mock's
    // pmdots.
    private func dotColors(for day: Int) -> [Color] {
        guard isDataMonth else { return [] }
        var seen = Set<String>()
        var colors: [Color] = []
        for de in CalendarData.expandedEvents(for: day, in: eventsByDay) {
            guard seen.insert(de.event.personId).inserted else { continue }
            colors.append(CalendarData.person(de.event.personId).color)
            if colors.count == 4 { break }
        }
        return colors
    }

    private func shiftMonth(by delta: Int) {
        var m = displayedMonth + delta
        var y = displayedYear
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = m; displayedYear = y }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(CalendarData.monthFull[displayedMonth - 1]) \(String(displayedYear))")
                    .font(Typography.font(24, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                Spacer()
                HStack(spacing: 8) {
                    Button { shiftMonth(by: -1) } label: { monthNavCircle("chevron.left") }
                    Button { shiftMonth(by: 1) } label: { monthNavCircle("chevron.right") }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(Typography.font(12, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 10) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    dayCell(d)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            // highPriorityGesture, not gesture — a plain .gesture here was
            // losing the touch to the sheet's own interactive-dismiss pan
            // recognizer, so swiping sideways to change months was instead
            // dragging the whole sheet down. Scoped to just the day grid
            // (not the sheet's header/handle), so a swipe down from there
            // still dismisses normally.
            .highPriorityGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -40 { shiftMonth(by: 1) }
                        else if value.translation.width > 40 { shiftMonth(by: -1) }
                    }
            )

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(EColor.surface)
    }

    private func monthNavCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(EColor.primary)
            .frame(width: 30, height: 30)
            .background(EColor.surfaceContainerLowest)
            .clipShape(Circle())
    }

    @ViewBuilder
    private func dayCell(_ d: Int?) -> some View {
        let isToday = isDataMonth && d == CalendarData.dataDay
        let isSel = isDataMonth && d == selectedDay && !isToday
        let isPickable = d != nil && isDataMonth

        Button {
            if let d, isDataMonth { onPickDay(d) }
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let d {
                        Text("\(d)")
                            .font(Typography.font(16, weight: isToday ? .heavy : .semibold))
                            .foregroundStyle(isToday ? .white : (isPickable ? EColor.onSurface : EColor.onSurfaceVariant.opacity(0.5)))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 38, height: 38)
                .background(isToday ? EColor.onSurface : (isSel ? EColor.primaryContainer : .clear))
                .clipShape(Circle())

                HStack(spacing: 2) {
                    if let d {
                        ForEach(Array(dotColors(for: d).enumerated()), id: \.offset) { _, c in
                            Circle().fill(c).frame(width: 4, height: 4)
                        }
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
        .disabled(!isPickable)
    }
}

// MARK: - Event detail / edit sheet

private struct EventDetailSheet: View {
    var dayEvent: CalDayEvent
    var onSave: (CalEvent) -> Void
    var onDelete: () -> Void
    var onClose: () -> Void

    @State private var editing = false
    @State private var draft: CalEvent
    @State private var showDeleteConfirm = false
    @State private var reminder = true
    // Real hour/minute pickers for Start/End (see editFields) need Date
    // state, but CalEvent stores them as display strings ("9:00 AM") — so
    // these live alongside `draft` rather than replacing it, parsed once
    // in init and re-parsed on Cancel (draft reverts there too; these
    // wouldn't otherwise, since they're not part of `draft` itself).
    @State private var startTime: Date
    @State private var endTime: Date
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

    private let categories = ["Activity", "Lesson", "Sport", "Family", "Routine", "Study", "Chore"]

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private static func parseClock(_ text: String, fallback: Date) -> Date {
        clockFormatter.date(from: text) ?? fallback
    }

    private var draftRepeatDays: Binding<Set<String>> {
        Binding(
            get: { draft.repeats == "none" ? [] : Set(draft.repeats.split(separator: ",").map(String.init)) },
            set: { days in
                let codes = weekDayCodes.filter { days.contains($0) }
                draft.repeats = codes.isEmpty ? "none" : codes.joined(separator: ",")
            }
        )
    }

    init(dayEvent: CalDayEvent, onSave: @escaping (CalEvent) -> Void, onDelete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.dayEvent = dayEvent
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        _draft = State(initialValue: dayEvent.event)
        _startTime = State(initialValue: Self.parseClock(dayEvent.event.start, fallback: Date()))
        _endTime = State(initialValue: Self.parseClock(dayEvent.event.end, fallback: Date().addingTimeInterval(3600)))
    }

    private var person: FamilyPerson { CalendarData.person(dayEvent.event.personId) }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    private var dateLabel: String {
        let name = CalendarData.dayNames[dayEvent.day] ?? ""
        let full = CalendarData.fullDayNames[name] ?? name
        return "\(full), September \(dayEvent.day)"
    }

    var body: some View {
        Group {
            // Editing now borrows AddCalendarSheet/AddTaskSheet's own
            // chrome (green "Cancel," big bold title, mint fields, full-
            // width Save pill) instead of the plain topBar+capsule-button
            // layout it used to have — so editing an event reads as the
            // same family of form as creating one, not a visually distinct
            // screen. View mode keeps its own layout; FormShell is
            // specifically an editing-form shell, not a fit for read-only
            // display.
            if editing {
                FormShell(
                    title: "Edit event",
                    onCancel: {
                        draft = dayEvent.event
                        startTime = Self.parseClock(dayEvent.event.start, fallback: startTime)
                        endTime = Self.parseClock(dayEvent.event.end, fallback: endTime)
                        editing = false
                    },
                    onSave: { onSave(draft) },
                    canSave: canSave,
                    saveLabel: "Save changes",
                    onDelete: { showDeleteConfirm = true }
                ) {
                    editFields
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    ScrollView { viewContent }
                        .scrollDismissesKeyboard(.interactively)
                        .dismissKeyboardOnTap()
                }
                .background(EColor.surface)
            }
        }
        // Only while actually editing — a swipe-to-dismiss in view mode is
        // perfectly safe (nothing to lose), but mid-edit it'd silently
        // discard whatever was typed, same risk FormShell's other callers
        // guard against.
        .interactiveDismissDisabled(editing)
        .alert("Delete \"\(dayEvent.event.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // Same header chrome as FormShell (green "Close" link, not a bare X)
    // so view mode reads as the same family of screen as the add/edit
    // forms — only the trailing actions differ, since there's nothing to
    // save here, just edit or delete.
    private var topBar: some View {
        HStack {
            Button("Close", action: onClose)
                .buttonStyle(.plain)
                .font(Typography.font(17, weight: .semibold))
                .foregroundStyle(FormGreen.accent)
                .frame(minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            Spacer(minLength: 12)
            Button { editing = true } label: {
                Image(systemName: "pencil").font(.system(size: 18, weight: .semibold)).foregroundStyle(FormGreen.accent).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(EColor.danger).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // Same shape as the add forms: big bold title, FormField's uppercase
    // tracked labels, mint field boxes — a read-only rendering of the
    // exact same fields Add Event asks for, not a different visual
    // language for "viewing" vs. "creating."
    private var viewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dayEvent.event.title)
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Text(dateLabel)
                .font(Typography.font(14, weight: .semibold))
                .foregroundStyle(EColor.onSurfaceVariant)
                .padding(.bottom, 20)

            FormField(label: "Time") {
                infoBox { Text("\(dayEvent.event.start) \u{2013} \(dayEvent.event.end)").font(Typography.font(15, weight: .medium)) }
            }

            if dayEvent.event.repeats != "none" {
                FormField(label: "Repeats") {
                    infoBox { Text(repeatDisplayLabel(dayEvent.event.repeats)).font(Typography.font(15, weight: .medium)) }
                }
            }

            FormField(label: "For") {
                infoBox {
                    HStack(spacing: 9) {
                        Circle().fill(person.color).frame(width: 24, height: 24)
                            .overlay(Text(String(person.name.prefix(1))).font(Typography.font(11, weight: .bold)).foregroundStyle(.white))
                        Text(person.name).font(Typography.font(15, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(dayEvent.event.category)
                            .font(Typography.font(11, weight: .bold))
                            .foregroundStyle(person.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(person.bg)
                            .clipShape(Capsule())
                    }
                }
            }

            if !dayEvent.event.location.isEmpty {
                FormField(label: "Location") {
                    infoBox { Text(dayEvent.event.location).font(Typography.font(15, weight: .medium)) }
                }
            }

            FormField(label: "Reminder") {
                infoBox {
                    HStack {
                        Text("30 minutes before").font(Typography.font(15, weight: .medium))
                        Spacer()
                        EToggle(on: $reminder)
                    }
                }
            }

            if !dayEvent.event.note.isEmpty {
                FormField(label: "Notes") {
                    infoBox { Text(dayEvent.event.note).font(Typography.font(15, weight: .regular)) }
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    // Same mint box every field in Add Task/Add Event sits in — this is
    // that same box, just holding a value instead of a control.
    private func infoBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(EColor.onSurface)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var editFields: some View {
        FormField(label: "Title") { FormTextField(placeholder: "Event title", text: $draft.title, scrollToTopOnFocus: true) }
        FormField(label: "Time") {
            HStack(spacing: 8) {
                FormTimeField(date: $startTime)
                Text("\u{2013}").foregroundStyle(EColor.onSurfaceVariant)
                FormTimeField(date: $endTime)
            }
        }
        // Nudges End along with Start so it doesn't silently end up before
        // it, same convenience as the add-event form, then keeps `draft`
        // (what Save actually writes back) in sync with both.
        .onChange(of: startTime) { oldValue, newValue in
            let span = endTime.timeIntervalSince(oldValue)
            endTime = newValue.addingTimeInterval(max(span, 900))
            draft.start = Self.clockFormatter.string(from: newValue)
        }
        .onChange(of: endTime) { _, newValue in draft.end = Self.clockFormatter.string(from: newValue) }
        RepeatPicker(selectedDays: draftRepeatDays)
        FormField(label: "Notes") {
            TextField("Add a note\u{2026}", text: $draft.note, axis: .vertical)
                .font(Typography.font(15, weight: .regular))
                .lineLimit(3...5)
                .padding(14)
                .background(FormGreen.fieldBg)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onChange(of: draft.note) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollFormToBottom()
                    }
                }
        }
        FormField(label: "Location") { FormTextField(placeholder: "Add location\u{2026}", text: $draft.location) }
        FormField(label: "Reminder") {
            HStack {
                Text("30 minutes before").font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurface)
                Spacer()
                EToggle(on: $reminder)
            }
            .padding(14).background(FormGreen.fieldBg).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Deadline group sheet — every task due at the same moment for the
// same kid opens here as one unit. Titled by the moment itself ("Due at
// 6:00 PM, your child"), one row per task (status box, name, status line,
// Approve). Approve acts in place — the sheet stays open, so clearing
// several tasks is quick — and tapping a row instead pushes to that task's
// full detail (TaskReviewDeckView, the same real review screen the rest of
// the app uses), with the chevron marking that it's a push, not an
// approval. No "Approve all": every task still gets looked at individually.
private struct TaskDueGroupSheet: View {
    var group: TaskDueGroup
    var onApprove: (CalDayEvent) -> Void
    var onClose: () -> Void

    // A local, mutable copy so Approve reflects instantly in this sheet's
    // own rows — CalEvent is a value type, so the array this was seeded
    // from won't update on its own just because the caller's eventsByDay
    // did via onApprove.
    @State private var tasks: [CalDayEvent]

    @State private var reviewTasks: [ChildTask] = []
    @State private var reviewChildName = ""
    // Needed to sync an approval back into both this sheet's own `tasks`
    // and the caller's eventsByDay (via onApprove) once review closes —
    // ChildTask ids aren't globally unique, only unique per child.
    @State private var reviewPersonId = ""
    @State private var reviewStartIndex = 0
    @State private var showTaskReview = false
    @State private var openChildId: String?

    init(group: TaskDueGroup, onApprove: @escaping (CalDayEvent) -> Void, onClose: @escaping () -> Void) {
        self.group = group
        self.onApprove = onApprove
        self.onClose = onClose
        _tasks = State(initialValue: group.tasks)
    }

    private var person: FamilyPerson { CalendarData.person(group.personId) }
    private var openCount: Int { tasks.filter { $0.event.taskState != .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Close", action: onClose)
                    .buttonStyle(.plain)
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text("Due at \(group.start), \(person.name)")
                .font(Typography.font(24, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 4)

            Text(openCount == 0 ? "All caught up" : "\(openCount) of \(tasks.count) still open")
                .font(Typography.font(14, weight: .semibold))
                .foregroundStyle(openCount == 0 ? Color(hex: "25924A") : EColor.onSurfaceVariant)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks) { de in
                        taskRow(de)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color.white)
        .fullScreenCover(item: Binding(get: { openChildId.map { IdentifiedString(value: $0) } }, set: { openChildId = $0?.value })) { wrapped in
            NavigationStack {
                ScreenProfile(childId: wrapped.value, onBack: { openChildId = nil })
            }
        }
        .fullScreenCover(isPresented: $showTaskReview) {
            TaskReviewDeckView(tasks: $reviewTasks, childName: reviewChildName, childId: reviewPersonId, startIndex: reviewStartIndex, onDismiss: {
                syncReviewedTasks()
                showTaskReview = false
            })
        }
    }

    // Any task approved from the full review deck needs both this sheet's
    // own row (so it doesn't sit there stale once the parent's back) and
    // the calendar's own CalEvent (via onApprove) caught up — ChildTask/
    // TaskStore and CalEvent/eventsByDay are two disconnected mock stores,
    // so nothing keeps them in sync automatically.
    private func syncReviewedTasks() {
        for reviewed in reviewTasks where reviewed.state == .done {
            if let i = tasks.firstIndex(where: { $0.event.personId == reviewPersonId && $0.event.linkedTaskId == reviewed.id }) {
                if tasks[i].event.taskState != .done {
                    tasks[i].event.taskState = .done
                    onApprove(tasks[i])
                }
            }
        }
    }

    // Same linkedTaskId routing ScreenCalendar's own onSelect uses for a
    // task with no group — a real counterpart goes straight to
    // TaskReviewDeckView; an ad-hoc task with nothing to review falls back
    // to the kid's profile. Presented from this sheet's own view (not the
    // calendar root), so dismissing it lands back here, not on the grid.
    private func openDetail(_ de: CalDayEvent) {
        let allTasks = TaskStore.tasks(for: de.event.personId)
        if let linkedId = de.event.linkedTaskId,
           let idx = allTasks.firstIndex(where: { $0.id == linkedId }) {
            reviewTasks = allTasks
            reviewChildName = person.name
            reviewPersonId = de.event.personId
            reviewStartIndex = idx
            showTaskReview = true
        } else {
            openChildId = de.event.personId
        }
    }

    private func approve(_ de: CalDayEvent) {
        if let i = tasks.firstIndex(where: { $0.id == de.id }) {
            tasks[i].event.taskState = .done
        }
        onApprove(de)
    }

    private func statusMeta(_ state: CalTaskState) -> (label: String, tone: Color) {
        switch state {
        case .done: return ("Approved", Color(hex: "25924A"))
        case .submitted: return ("Awaiting your review", Color(hex: "B26A00"))
        case .pending: return ("Waiting on \(person.name)", EColor.onSurfaceVariant)
        }
    }

    private func statusBox(_ state: CalTaskState) -> some View {
        let (bg, icon, iconColor): (Color, String?, Color) = {
            switch state {
            case .done: return (Color(hex: "25924A").opacity(0.12), "checkmark", Color(hex: "25924A"))
            case .submitted: return (Color(hex: "FFA726").opacity(0.16), "exclamationmark", Color(hex: "B26A00"))
            case .pending: return (EColor.outlineVariant.opacity(0.5), nil, EColor.onSurfaceVariant)
            }
        }()
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(bg)
            .frame(width: 32, height: 32)
            .overlay {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(iconColor)
                }
            }
    }

    private func taskRow(_ de: CalDayEvent) -> some View {
        let ev = de.event
        let meta = statusMeta(ev.taskState)
        return HStack(spacing: 10) {
            Button { openDetail(de) } label: {
                HStack(spacing: 12) {
                    statusBox(ev.taskState)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.title)
                            .font(Typography.font(15, weight: .semibold))
                            .foregroundStyle(EColor.onSurface)
                            .strikethrough(ev.taskState == .done)
                        Text(meta.label)
                            .font(Typography.font(12.5, weight: .medium))
                            .foregroundStyle(meta.tone)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if ev.taskState != .done {
                Button("Approve") { approve(de) }
                    .buttonStyle(.plain)
                    .font(Typography.font(13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(hex: "25924A"))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Add event

// A parent adding something to the calendar means two different things —
// a Task (something the kid does and checks off, same as chat's "Add a
// task" or a child profile's Add Task) or an Event (a family/kid activity
// with a time range, no completion concept). Asking which up front, rather
// than the old single "Add to Calendar" form, means each one only shows
// the fields that actually apply instead of a event-shaped form standing
// in for both. Both still land in the same eventsByDay store (the only
// persistent-this-session state ScreenCalendar owns), so a task shows up
// on the day timeline the same way an event does, just tagged category
// "Task" — this prototype has no cross-screen task sync (see KidTask's
// bypassRequested doc comment for the same limitation elsewhere), so it
// isn't wired into a specific kid's own task list.
private struct AddCalendarSheet: View {
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void
    var onCancel: () -> Void

    private enum Kind: Equatable { case task, event }
    @State private var kind: Kind?
    // Both detents stay in the allowed set at all times; which one is
    // *active* is driven by this selection instead of swapping the array
    // itself (the array used to be [kind == nil ? .height(340) : .large] —
    // changing which detents are *allowed* doesn't reliably make the sheet
    // animate into the newly-valid one, so picking a kind could leave the
    // sheet stuck at its old, smaller height until a parent manually
    // dragged it open). Setting the selection directly is what actually
    // triggers a real, immediate system-driven resize animation.
    @State private var detentSelection: PresentationDetent = .height(340)

    var body: some View {
        Group {
            switch kind {
            case .none:
                kindPicker
            case .event:
                AddCalendarEventForm(currentDay: currentDay, onCreate: onCreate, onCancel: { kind = nil })
            case .task:
                AddCalendarTaskForm(currentDay: currentDay, onCreate: onCreate, onCancel: { kind = nil })
            }
        }
        // Not a range to drag between — the picker step is two tiles tall
        // and the forms after it need real scroll room, but neither should
        // be something a parent can drag-resize by hand; this only ever
        // changes because `kind` did. No drag indicator either, since
        // there's nothing here to drag to.
        .presentationDetents([.height(340), .large], selection: $detentSelection)
        .presentationDragIndicator(.hidden)
        .onChange(of: kind) { _, newValue in
            detentSelection = newValue == nil ? .height(340) : .large
        }
        // Tap-outside-to-dismiss only while nothing's been typed yet (the
        // picker step) — once a form is up, an accidental tap on the
        // scrim shouldn't silently drop what a parent already filled in;
        // Cancel is still right there for that.
        .interactiveDismissDisabled(kind != nil)
    }

    // FormShell's own chrome (green Cancel link, big bold title) instead
    // of a system nav bar, so this first step reads as the same sheet as
    // whichever form comes after it, not a different screen bolted on
    // front. Two plain tiles, icon and label only — no description text,
    // no card border, no chevron. What a task vs. an event *is* belongs
    // in the form each one opens, not a sentence here to read first.
    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Typography.font(17, weight: .semibold))
                    .foregroundStyle(FormGreen.accent)
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Text("Add to Calendar")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)

            HStack(spacing: 14) {
                kindTile(title: "Task", systemImage: "checkmark.circle.fill") { kind = .task }
                kindTile(title: "Event", systemImage: "calendar") { kind = .event }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .background(Color.white)
    }

    // A solid, full-color icon tile — not a small tinted glyph — so which
    // is which reads at a glance rather than needing the label to do all
    // the work.
    private func kindTile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(FormGreen.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(title).font(Typography.font(16, weight: .bold)).foregroundStyle(FormGreen.title)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(FormGreen.fieldBg)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Ported from Evlin-iOS's AddCalendarForm (Views/Profile/AddBottomSheet.swift):
// Title, a free-text Start-End time pair, a category pill row (each with its
// own emoji, via `emojiForCalendarCategory`), and a Repeat pill row - same
// field set and FormShell chrome as AddTaskSheet, so "add event" feels like
// the same family of sheet as "add task."
private struct AddCalendarEventForm: View {
    // The day this lands on isn't pickable here — an event stays scoped
    // to whichever day the parent already had open, same as before; only
    // Add Task grew a real date picker (see AddCalendarTaskForm).
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void
    var onCancel: () -> Void

    private var lanePeople: [FamilyPerson] {
        var people = [FamilyPerson(id: "family", name: "Parent", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))]
        for child in FamilyStore.children {
            people.append(FamilyPerson(id: child.id, name: child.name, color: child.color, bg: child.color.opacity(0.15)))
        }
        return people
    }
    @State private var personId = "family"
    @State private var title = ""
    // Real hour/minute pickers now, not free-text — defaults to the next
    // half-hour with a 1-hour span, so opening the sheet already shows a
    // sensible time instead of an empty field to fill in.
    @State private var startTime: Date = AddCalendarEventForm.roundedToNextHalfHour(Date())
    @State private var endTime: Date = AddCalendarEventForm.roundedToNextHalfHour(Date()).addingTimeInterval(3600)
    // Fixed rather than parent-picked — see removed "Category" FormField
    // below. Still feeds CalEvent.category/emoji since other screens (the
    // day-view Pill, etc.) read those.
    private let category = "Activity"
    @State private var repeatDays: Set<String> = []

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func roundedToNextHalfHour(_ date: Date) -> Date {
        let cal = Calendar.current
        let minute = cal.component(.minute, from: date)
        let addMinutes = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(byAdding: .minute, value: addMinutes, to: date) ?? date
    }

    var body: some View {
        FormShell(title: "Add Event", onCancel: onCancel, onSave: {
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            onCreate(CalEvent(
                personId: personId, title: title, emoji: emojiForCalendarCategory(category),
                start: ChildRule.fmtClock(startTime), end: ChildRule.fmtClock(endTime), category: category,
                location: "", note: "", repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
            ), currentDay)
        }, canSave: canSave, saveLabel: "Add event") {
            FormField(label: "Title") {
                FormTextField(placeholder: "e.g. Piano Practice", text: $title, scrollToTopOnFocus: true)
            }
            FormField(label: "For") {
                FlowChips {
                    ForEach(lanePeople + [CalendarData.everyone]) { p in
                        DotChip(label: p.name, color: p.color, selected: personId == p.id) { personId = p.id }
                    }
                }
            }
            FormField(label: "Time") {
                HStack(spacing: 8) {
                    FormTimeField(date: $startTime)
                    Text("-").font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
                    FormTimeField(date: $endTime)
                }
            }
            // Nudges End along with Start so it doesn't silently end up
            // before it — picking a new Start is the common edit; End only
            // needs a parent's attention when they actually want a
            // different duration, not every time.
            .onChange(of: startTime) { oldValue, newValue in
                let span = endTime.timeIntervalSince(oldValue)
                endTime = newValue.addingTimeInterval(max(span, 900))
            }
            RepeatPicker(selectedDays: $repeatDays)
        }
    }
}

// Task-shaped fields (title, who, due, what to do, repeat) instead of a
// time range — a task's "when" is a single due moment, not a start/end
// span, and it needs instructions the way an event doesn't. Still produces
// a CalEvent (category "Task") since that's the only store this screen has
// to put it in; the day timeline gives it a short nominal block at its due
// time rather than the freeform span an event gets.
private struct AddCalendarTaskForm: View {
    // Which day this opened from — the fallback target when no due date
    // is picked at all (an undated task still has to land somewhere).
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void
    var onCancel: () -> Void

    private var lanePeople: [FamilyPerson] {
        var people = [FamilyPerson(id: "family", name: "Parent", color: Color(hex: "7C6FF7"), bg: Color(hex: "EDE9FE"))]
        for child in FamilyStore.children {
            people.append(FamilyPerson(id: child.id, name: child.name, color: child.color, bg: child.color.opacity(0.15)))
        }
        return people
    }
    @State private var personId = FamilyStore.children.first?.id ?? "family"
    @State private var title = ""
    @State private var whatToDo = ""
    // Same "When" field as a profile's own Add Task — no due date at all
    // (an ANYTIME task), or a real date + time from any day on the
    // calendar, not just today or tomorrow.
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var repeatDays: Set<String> = []

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    // The mock day being viewed has nothing to do with the real device
    // calendar — day 12 here doesn't mean "the 12th of whatever real
    // month it is." Overriding just the day component onto today's real
    // year/month/time keeps the picker's default (and its allowed range)
    // anchored to the actual day the parent has open, so "Add a date &
    // time" can't silently default to a day they aren't even looking at.
    private var viewedDayDefault: Date {
        var comps = Calendar.current.dateComponents([.year, .month, .hour, .minute], from: Date())
        comps.day = currentDay
        return Calendar.current.date(from: comps) ?? Date()
    }

    var body: some View {
        AddTaskFormFields(
            title: "Add Task", saveLabel: "Add task", fixedChild: nil,
            taskTitle: $title, personId: $personId, whatToDo: $whatToDo, repeatDays: $repeatDays,
            canSave: canSave, onCancel: onCancel, onSave: {
                let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
                let targetDay = hasDueDate ? Calendar.current.component(.day, from: dueDate) : currentDay
                onCreate(CalEvent(
                    personId: personId, title: title, emoji: emojiForCalendarCategory("Task"),
                    start: hasDueDate ? ChildRule.fmtClock(dueDate) : "12:00 AM",
                    end: hasDueDate ? ChildRule.fmtClock(dueDate.addingTimeInterval(1800)) : "12:00 AM",
                    category: "Task", location: "", note: whatToDo.trimmingCharacters(in: .whitespaces),
                    repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ","),
                    isAnytime: !hasDueDate
                ), targetDay)
            }
        ) {
            TaskWhenField(
                hasDueDate: $hasDueDate, dueDate: $dueDate,
                defaultDate: viewedDayDefault,
                minDate: Calendar.current.date(byAdding: .day, value: -31, to: viewedDayDefault) ?? viewedDayDefault
            )
        }
    }
}
