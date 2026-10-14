import SwiftUI

// The parent's Calendar tab: a Day view (a Tasks line, then an hour grid of
// events) and a Week agenda, built on DayTimelineView, which the kid's
// calendar (ScreenTabletCalendar) shares in a read-only style. Also the
// sheets it opens: event detail/edit, the day's tasks, and adding an event
// or task.

// Time-grid geometry: one row of hourHeight per hour, midnight to midnight.
let hourHeight: CGFloat = 56
let startHour = 0
let endHour = 24
let timeColW: CGFloat = 46
// The day grid's right margin, matched by the chips above it.
let gridTrailing: CGFloat = 16

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

// Lays out a day's events on the grid. Each child shown has a fixed lane
// for the whole day, in the order of the child chips, so a child's events
// always sit in their own column. Within one lane, events that overlap in
// time get side-by-side sub-columns (splitOverlaps).
func layoutDayEvents(_ events: [CalDayEvent], lanes: [FamilyPerson]) -> [LaidOutEvent] {
    let numCols = max(lanes.count, 1)
    let items: [LaidOutEvent] = events.compactMap { de -> LaidOutEvent? in
        // Matched by id, not by position: lanes and events are filtered
        // separately.
        guard let colIndex = lanes.firstIndex(where: { $0.id == de.event.personId }) else { return nil }
        let start = evTop(de.event.start)
        let end = max(evTop(de.event.end), start + 1)
        return LaidOutEvent(id: de.id, dayEvent: de, top: start, height: end - start, col: colIndex, numCols: numCols)
    }
    // Overlap is worked out per lane; two children's events never share
    // a sub-column.
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

struct ScreenCalendar: View {
    // True while the Calendar tab is the selected one. TabView keeps every
    // tab's view alive across switches rather than recreating it, so
    // .onAppear only ever fires once, the very first time this tab is
    // visited. Watching this instead catches every re-entry, which is
    // when the day page scrolls back to its top.
    var isActive: Bool = true
    @State private var selectedDay = CalendarData.dataDay
    // The displayed month, read from the phone's database (TaskStore). Every
    // edit below is written there, so it's on screen the moment it's made;
    // the outbox sends it.
    private var eventsByDay: [Int: [CalEvent]] { TaskStore.shared.calendar }
    @State private var saveFailed = false
    @State private var saveError = ""
    @State private var activeDayEvent: CalDayEvent?
    // A long-press "Edit" opens the event sheet straight in its edit form.
    @State private var activeDayEventEditing = false
    // A long-press "Delete" still asks first.
    @State private var pendingDeleteEvent: CalDayEvent?
    // The day's task list (DayTasksSheet), when open. Reviewing happens
    // from Home, so tasks here only open this list, never the review deck.
    @State private var tasksSheet: TasksSheetTarget?
    @State private var showAddEvent = false
    // A success tap when a new task or event is saved, as for an approval.
    @State private var createdTick = 0
    // The child chip picked at the top: nil shows everyone, so a newly
    // added child is visible the moment they exist.
    @State private var focusedChildId: String?
    // A task opened for editing from a long-press in Week.
    @State private var editingTask: ChildTask?
    @State private var editingTaskPersonId = ""

    // One lane per child. Evlin keeps the children's calendars only: no
    // parent lane, no family-wide events.
    private var lanePeople: [FamilyPerson] { CalendarData.people }

    private func expandedEvents(for day: Int) -> [CalDayEvent] {
        CalendarData.expandedEvents(for: day, in: eventsByDay)
    }

    // Read fresh on every render, so the open sheet follows a sync.
    private func tasks(for target: TasksSheetTarget) -> [CalDayEvent] {
        expandedEvents(for: target.day).filter { $0.event.category == "Task" && target.personIds.contains($0.event.personId) }
    }

    // MARK: Backend saves

    private static func dayString(_ day: Int) -> String {
        String(format: "%04d-%02d-%02d", CalendarData.dataYear, CalendarData.dataMonth, day)
    }

    private static func dueTimeString(_ clock: String) -> String {
        let m = CalendarData.minutesSinceMidnight(clock)
        return String(format: "%02d:%02d:00", m / 60, m % 60)
    }

    private static func eventDates(_ ev: CalEvent, day: Int) -> (Date, Date) {
        let start = CalendarData.date(day: day, minutes: CalendarData.minutesSinceMidnight(ev.start))
        var end = CalendarData.date(day: day, minutes: CalendarData.minutesSinceMidnight(ev.end))
        if end < start { end = start.addingTimeInterval(3600) }
        return (start, end)
    }

    private func createItem(_ ev: CalEvent, day: Int) {
        // Tasks and events both belong to a real child.
        guard FamilyStore.children.contains(where: { $0.id == ev.personId }) else {
            saveError = "Pick which child this is for."
            saveFailed = true
            return
        }
        if ev.category == "Task" {
            TaskEdits.create(
                childId: ev.personId, title: ev.title,
                instructions: ev.note.isEmpty ? nil : ev.note,
                recurrence: ev.repeats, category: "Task",
                dueTime: ev.isAnytime ? nil : Self.dueTimeString(ev.start),
                dueDate: Self.dayString(day)
            )
        } else {
            let id = APIClient.Write.newId()
            let (start, end) = Self.eventDates(ev, day: day)
            LocalStore.shared.mirrorEventSaved(CalendarSync.apiEvent(ev, id: id, start: start, end: end))
            Outbox.send(APIClient.Write.createEvent(
                id: id, childId: ev.personId, title: ev.title, start: start, end: end,
                category: ev.category, note: ev.note, location: ev.location, recurrence: ev.repeats
            ), childId: ev.personId, label: "The new event")
        }
    }

    // `approve`: a kid's waiting plan, saved with the parent's changes and
    // approved in one go.
    private func updateItem(_ updated: CalEvent, originDay: Int, approve: Bool = false) {
        var shown = updated
        if approve { shown.planStatus = .approved }
        guard let remoteId = updated.remoteId else { return }
        let (start, end) = Self.eventDates(updated, day: originDay)
        LocalStore.shared.mirrorEventSaved(CalendarSync.apiEvent(shown, id: remoteId, start: start, end: end))
        Outbox.send(APIClient.Write.updateEvent(
            eventId: remoteId, childId: updated.personId, title: updated.title, start: start, end: end,
            category: updated.category, note: updated.note, location: updated.location,
            recurrence: updated.repeats
        ), childId: updated.personId, label: "Your event edit")
        if approve {
            Outbox.send(APIClient.Write.approvePlan(eventId: remoteId), childId: updated.personId, label: "Approving the plan")
        }
    }

    // The parent's answer to a kid's plan.
    private func answerPlan(_ ev: CalEvent, originDay: Int, approve: Bool, note: String = "") {
        var shown = ev
        shown.planStatus = approve ? .approved : .declined
        if !approve { shown.reviewNote = note.isEmpty ? nil : note }
        guard let remoteId = ev.remoteId else { return }
        let (start, end) = Self.eventDates(ev, day: originDay)
        LocalStore.shared.mirrorEventSaved(CalendarSync.apiEvent(shown, id: remoteId, start: start, end: end))
        Outbox.send(approve
                    ? APIClient.Write.approvePlan(eventId: remoteId)
                    : APIClient.Write.declinePlan(eventId: remoteId, note: note),
                    childId: ev.personId, label: approve ? "Approving the plan" : "Your answer")
    }

    // A task edited from the day list: saved through the same path as the
    // review deck's edit.
    private func saveTask(_ updated: ChildTask, personId: String) {
        // Whether it had a deadline before: removing one clears it.
        let hadDeadline = eventsByDay.values.joined()
            .first { $0.personId == personId && $0.linkedTaskId == updated.id }
            .map { !$0.isAnytime } ?? false
        TaskEdits.save(updated, clearDueTime: hadDeadline && updated.dueLabel == nil)
    }

    private func deleteTask(_ task: ChildTask, personId: String) {
        withAnimation(.snappy(duration: 0.3)) { TaskEdits.delete(task) }
    }

    private func deleteItem(_ ev: CalEvent, originDay: Int) {
        guard let remoteId = ev.remoteId else { return }
        withAnimation(.snappy(duration: 0.3)) { LocalStore.shared.mirrorEventDeleted(id: remoteId) }
        Outbox.send(APIClient.Write.deleteEvent(eventId: remoteId), childId: ev.personId, label: "Deleting the event")
    }

    var body: some View {
        NavigationStack {
            DayTimelineView(
                selectedDay: $selectedDay,
                visiblePeople: lanePeople,
                focusedChildId: $focusedChildId,
                isActive: isActive,
                eventsByDay: eventsByDay,
                onSelect: { de in
                    activeDayEventEditing = false
                    activeDayEvent = de
                },
                onShowTasks: { day, ids in tasksSheet = TasksSheetTarget(day: day, personIds: ids) },
                onEditTask: { de in
                    editingTaskPersonId = de.event.personId
                    editingTask = calendarEditableTask(de)
                },
                onEditEvent: { de in
                    activeDayEventEditing = true
                    activeDayEvent = de
                },
                onDeleteEvent: { de in pendingDeleteEvent = de },
                onPickDate: { year, month, d in
                    if year == CalendarData.dataYear && month == CalendarData.dataMonth {
                        selectedDay = d
                    } else {
                        Task {
                            await AppSync.shared.loadCalendarMonth(year: year, month: month)
                            selectedDay = d
                        }
                    }
                },
                onAdd: { showAddEvent = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .navigationBarHidden(true)
        }
        .sheet(item: $activeDayEvent) { de in
            Group {
            let waitingPlan = de.event.isKidPlan && de.event.planStatus == .proposed
            EventDetailSheet(dayEvent: de, startEditing: activeDayEventEditing, onSave: { updated in
                updateItem(updated, originDay: de.originDay, approve: waitingPlan)
                activeDayEvent = nil
            }, onDelete: {
                deleteItem(de.event, originDay: de.originDay)
                activeDayEvent = nil
            }, onClose: { activeDayEvent = nil },
            onApprove: waitingPlan ? {
                answerPlan(de.event, originDay: de.originDay, approve: true)
                activeDayEvent = nil
            } : nil,
            onDecline: waitingPlan ? { note in
                answerPlan(de.event, originDay: de.originDay, approve: false, note: note)
                activeDayEvent = nil
            } : nil)
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $tasksSheet) { target in
            Group {
            DayTasksSheet(
                people: target.personIds.map { CalendarData.person($0) },
                tasks: tasks(for: target),
                onSaveTask: saveTask,
                onDeleteTask: deleteTask,
                onClose: { tasksSheet = nil }
            )
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddEvent) {
            Group {
            AddCalendarSheet(currentDay: selectedDay, onCreate: { ev, day in
                createItem(ev, day: day)
                createdTick += 1
                showAddEvent = false
            })
        }
            .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.success, trigger: createdTick)
        // Past midnight: a calendar that was on today moves to the new today.
        .onChange(of: DayClock.shared.today) { old, new in
            selectedDay = CalendarData.followingToday(selectedDay, from: old, to: new)
        }
        .alert(
            "Delete \"\(pendingDeleteEvent?.event.title ?? "")\"?",
            isPresented: Binding(get: { pendingDeleteEvent != nil }, set: { if !$0 { pendingDeleteEvent = nil } }),
            presenting: pendingDeleteEvent
        ) { de in
            Button("Delete", role: .destructive) { deleteItem(de.event, originDay: de.originDay) }
            Button("Cancel", role: .cancel) {}
        } message: { de in
            Text(de.isRecurring ? "This removes every repeat. It can't be undone." : "This can't be undone.")
        }
        .alert("Couldn't save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError)
        }
        .sheet(item: $editingTask) { task in
            Group {
            EditTaskReviewSheet(
                task: task,
                onSave: { updated in
                    saveTask(updated, personId: editingTaskPersonId)
                    editingTask = nil
                },
                onDelete: {
                    // The sheet slides away first, then the task leaves.
                    let personId = editingTaskPersonId
                    editingTask = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + TaskEdits.sheetCloseDelay) {
                        deleteTask(task, personId: personId)
                    }
                },
                onCancel: { editingTask = nil }
            )
            .presentationDetents([.large])
        }
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Day timeline

// The calendar both sides share: the parent's Calendar tab, and the kid's
// (ScreenTabletCalendar) with `style: .kid`, read-only in kid colours.
//
// A fixed header (month title with a drop-down month grid, the Day/Week
// switch, and child chips when there's more than one child), then one
// scrolling page. Day: a Tasks line (opens DayTasksSheet) above an hour
// grid of events. Week: an agenda of the selected day and the six after.
// Swipe changes the day (a week in Week), pinch switches Day/Week, and a
// long-press on the title goes to today.
enum CalendarMode { case day, week }

// What differs between the parent's calendar and the kid's: colours, the
// heading font, and whether anything can be edited. The kid side only
// looks; editing stays a parent action.
struct CalendarStyle {
    var readOnly: Bool
    var ink: Color
    var inkSoft: Color
    var line: Color
    var cardLine: Color
    var pageBg: Color
    var segmentBg: Color
    var accent: Color
    var addColor: Color
    var addLabel: String
    var title: (CGFloat) -> Font

    static let parent = CalendarStyle(
        readOnly: false,
        ink: EColor.onSurface, inkSoft: EColor.onSurfaceVariant, line: EColor.outlineVariant,
        cardLine: Color(hex: "ECEEEC"), pageBg: Color(hex: "F7F8F7"), segmentBg: Color(hex: "F0F1F0"),
        accent: Brand.ink,
        addColor: Brand.ink, addLabel: "Add to the calendar",
        title: { Typography.font($0, weight: .heavy) }
    )

    static let kid = CalendarStyle(
        readOnly: true,
        ink: KidTheme.ink, inkSoft: KidTheme.inkSoft, line: KidTheme.line,
        cardLine: KidTheme.line, pageBg: KidTheme.background, segmentBg: KidTheme.muted,
        accent: KidTheme.greenDeep,
        addColor: KidTheme.greenDeep, addLabel: "Plan something",
        title: { Typography.display($0 + 2, weight: .bold) }
    )
}

struct DayTimelineView: View {
    @Binding var selectedDay: Int
    var visiblePeople: [FamilyPerson]
    // nil is everyone.
    @Binding var focusedChildId: String?
    var isActive: Bool
    var eventsByDay: [Int: [CalEvent]]
    // An event tapped (parent: its detail sheet), or on the read-only kid
    // calendar, any item tapped (a quick look at it).
    var onSelect: (CalDayEvent) -> Void
    // Opens the day's task list (DayTasksSheet): which day, and whose.
    var onShowTasks: (Int, [String]) -> Void = { _, _ in }
    var onEditTask: (CalDayEvent) -> Void = { _ in }
    var onEditEvent: (CalDayEvent) -> Void = { _ in }
    var onDeleteEvent: (CalDayEvent) -> Void = { _ in }
    var onPickDate: (Int, Int, Int) -> Void
    // The Day page's + button; nil for none.
    var onAdd: (() -> Void)? = nil
    var style: CalendarStyle = .parent

    @State private var mode: CalendarMode = .day
    @State private var showMonth = false
    // Which way the page slides when the date changes: forward comes in
    // from the right, like turning a page.
    @State private var slideForward = true
    // The day page the pager is on (Day view).
    @State private var pagerDay: Int?
    // The day page's sideways offset while a finger drags it.
    @State private var pageDrag: CGFloat = 0
    @State private var dragSideways: Bool?
    // When the page last moved (a drag, a scroll, a day change). Taps on
    // events and rows count only once it's been still a moment, so the
    // finger that ends a swipe or a scroll never opens what it lands on.
    @State private var lastMotion = Date.distantPast
    private var pageIsStill: Bool { Date().timeIntervalSince(lastMotion) > 0.3 }

    private var showsChips: Bool { visiblePeople.count > 1 }

    // A focused child who has since been removed reads as everyone.
    private var activePeople: [FamilyPerson] {
        if let id = focusedChildId, let p = visiblePeople.first(where: { $0.id == id }) { return [p] }
        return visiblePeople
    }

    // Who each item belongs to only needs saying when several children
    // share the view.
    private var showsOwner: Bool { activePeople.count > 1 }

    private func items(for day: Int) -> [CalDayEvent] {
        let ids = Set(activePeople.map(\.id))
        // A plan the parent turned down stays only on the kid's calendar.
        return CalendarData.expandedEvents(for: day, in: eventsByDay).filter {
            ids.contains($0.event.personId) && (style.readOnly || $0.event.planStatus != .declined)
        }
    }

    private func filteredEvents(_ day: Int) -> [CalDayEvent] { items(for: day) }

    // Tasks never go on the hour grid, which is for events (things that
    // take up time). They're counted on the Tasks line and listed in
    // DayTasksSheet.
    private func dayTasks(_ day: Int) -> [CalDayEvent] { filteredEvents(day).filter { $0.event.category == "Task" } }

    private var isToday: Bool { isToday(selectedDay) }
    private func isToday(_ day: Int) -> Bool { day == CalendarData.dataDay && CalendarData.isDisplayingCurrentMonth }

    // The grid runs to midnight, but starts at 7 AM unless an event on
    // the day (or the current time, today) is earlier — the Tasks card
    // sits above it, and opening on empty small hours below that card
    // would push the day itself off the screen.
    private func rangeStartHour(_ day: Int) -> Int {
        var earliest = 7
        for de in filteredEvents(day) where de.event.category != "Task" {
            earliest = min(earliest, CalendarData.minutesSinceMidnight(de.event.start) / 60)
        }
        if isToday(day) { earliest = min(earliest, nowMinutes / 60) }
        return max(startHour, earliest)
    }
    private var rangeEndHour: Int { endHour }
    private func rangeStartY(_ day: Int) -> CGFloat { timeToY(rangeStartHour(day)) }
    // Labels/dividers draw one line per boundary, through the closing line
    // at midnight (fmtHour(24) prints nothing).
    private func hours(_ day: Int) -> [Int] { Array(rangeStartHour(day)...rangeEndHour) }

    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func showNowLine(_ day: Int) -> Bool {
        isToday(day) && nowMinutes >= rangeStartHour(day) * 60 && nowMinutes <= rangeEndHour * 60
    }

    // The page for one date. A new id on every date change is what lets
    // the old page slide out while the new one slides in.
    private var dateId: String {
        "\(CalendarData.dataYear)-\(CalendarData.dataMonth)-\(selectedDay)"
    }

    // Two layers, so each change gets its own motion. Changing the date
    // slides (the inner id). Switching Day/Week is the same date seen
    // differently, so it doesn't slide: the old view goes at once and the
    // new one fades in — never two layouts drifting over each other.
    private var modePage: some View {
        ZStack {
            switch mode {
            case .day:
                dayPager
            case .week:
                weekPage
                    .id(dateId)
                    .offset(x: pageDrag)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading),
                        removal: .move(edge: slideForward ? .leading : .trailing)
                    ))
            }
        }
        .id(mode)
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the page, so nothing animating below can cover it.
            VStack(spacing: 0) {
                header
                Divider()
            }
            .zIndex(3)
            ZStack(alignment: .top) {
                modePage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Adding is for a day, so the + is part of the Day page.
                // An inset, not an overlay, so the grid's last hour can
                // scroll clear of it.
                .safeAreaInset(edge: .bottom) {
                    if mode == .day, let onAdd { addButton(onAdd) }
                }
                // Down behind the + button and the tab bar too, so the
                // page doesn't end in a white band above them.
                .background(style.pageBg.ignoresSafeArea(edges: .bottom))
                // Swipe sideways for the next or previous day (a week at a
                // time in Week). Simultaneous, so vertical scrolling is
                // untouched; only a clearly sideways flick counts.
                // As in Google Calendar, the page follows the finger and a
                // long enough or fast enough swipe carries on to the next
                // day; each drag is decided once at its start (sideways or a
                // scroll), so a scroll never nudges the page.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { v in
                            lastMotion = Date()
                            guard mode == .week else { return }
                            let dx = v.translation.width, dy = v.translation.height
                            // Decided once, after the finger has moved a
                            // little: clearly sideways, or it's a scroll and
                            // the page never moves.
                            if dragSideways == nil, hypot(dx, dy) > 18 {
                                dragSideways = abs(dx) > abs(dy) * 2
                            }
                            guard dragSideways == true else { return }
                            pageDrag = dx * 0.6
                        }
                        .onEnded { v in
                            lastMotion = Date()
                            defer { dragSideways = nil }
                            guard mode == .week else { return }
                            guard dragSideways == true else { return }
                            let dx = v.translation.width
                            let projected = v.predictedEndTranslation.width
                            // A real swipe: far enough, or a firm flick the
                            // same way the finger went.
                            let flick = abs(projected) > 260 && (projected < 0) == (dx < 0)
                            if abs(dx) > 110 || (abs(dx) > 40 && flick) {
                                // The page carries on from where the finger
                                // left it; the day's slide resets the drag.
                                stepDay(by: (dx < 0 ? 1 : -1) * (mode == .week ? 7 : 1))
                            } else {
                                withAnimation(.spring(duration: 0.35, bounce: 0)) { pageDrag = 0 }
                            }
                        }
                )
                // Pinch in to zoom out to the week, pinch out to come back
                // to the day.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onEnded { v in
                            if v.magnification < 0.8, mode == .day { setMode(.week) }
                            else if v.magnification > 1.25, mode == .week { setMode(.day) }
                        }
                )
                .accessibilityAction(named: mode == .week ? "Next week" : "Next day") {
                    stepDay(by: mode == .week ? 7 : 1)
                }
                .accessibilityAction(named: mode == .week ? "Previous week" : "Previous day") {
                    stepDay(by: mode == .week ? -7 : -1)
                }

                // Two layers with their own transitions: the dim only
                // fades, and the panel unfolds from under the title.
                // zIndex keeps both above the page while they animate out.
                if showMonth {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea(edges: .bottom)
                        .onTapGesture { setMonthOpen(false) }
                        .transition(.opacity)
                        .zIndex(1)
                    monthPanel
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .top))
                                .combined(with: .offset(y: -10)),
                            removal: .opacity.combined(with: .offset(y: -6))
                        ))
                        .zIndex(2)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay)
        .sensoryFeedback(.impact(weight: .light), trigger: mode)
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(style.addColor, in: Circle())
                    .shadow(color: style.addColor.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(style.addLabel)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private func setMode(_ m: CalendarMode) {
        guard m != mode else { return }
        withAnimation(.easeOut(duration: 0.18)) { mode = m }
    }

    private static let pageSpring = Animation.spring(response: 0.38, dampingFraction: 0.9)

    // Long-press on the month title: back to today from anywhere, loading
    // today's month first if another one is showing.
    private func goToday() {
        setMonthOpen(false)
        if CalendarData.isDisplayingCurrentMonth {
            guard selectedDay != CalendarData.dataDay else { return }
            slideForward = CalendarData.dataDay > selectedDay
            withAnimation(Self.pageSpring) { selectedDay = CalendarData.dataDay }
        } else {
            slideForward = (CalendarData.todayYear, CalendarData.todayMonth) > (CalendarData.dataYear, CalendarData.dataMonth)
            onPickDate(CalendarData.todayYear, CalendarData.todayMonth, CalendarData.dataDay)
        }
    }

    // A soft spring to open, a quicker ease to close — closing is the
    // parent moving on, so it shouldn't linger.
    private func setMonthOpen(_ open: Bool) {
        withAnimation(open ? .spring(response: 0.34, dampingFraction: 0.86) : .easeOut(duration: 0.16)) {
            showMonth = open
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Text("\(CalendarData.monthFull[CalendarData.dataMonth - 1]) \(String(CalendarData.dataYear))")
                        .font(style.title(21))
                        .foregroundStyle(style.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(style.inkSoft)
                        .rotationEffect(.degrees(showMonth ? 180 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { setMonthOpen(!showMonth) }
                .onLongPressGesture(minimumDuration: 0.45) { goToday() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the month to pick a date. Long-press to go to today.")
                .accessibilityAction(named: "Go to today") { goToday() }
                Spacer()
                dateBadge
            }

            segmented

            if showsChips { childChips }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.white)
    }

    // The day being shown (in Week, the span). Dark when it's today (or
    // the week includes today), muted grey otherwise.
    private var dateBadge: some View {
        let todayShown = mode == .day ? isToday : weekDays.contains(CalendarData.dataDay) && CalendarData.isDisplayingCurrentMonth
        let label = mode == .day
            ? "\(CalendarData.dayNames[selectedDay] ?? ""), \(CalendarData.monthShort) \(selectedDay)"
            : "\(CalendarData.monthShort) \(weekDays.first ?? selectedDay) – \(weekDays.last ?? selectedDay)"
        return Text(label)
            .font(Typography.font(14, weight: .bold))
            .foregroundStyle(todayShown ? style.ink : style.inkSoft)
            .accessibilityLabel(todayShown ? "\(label), today" : label)
        .contentTransition(.numericText())
        .animation(.easeOut(duration: 0.2), value: label)
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            segment("Day", .day)
            segment("Week", .week)
        }
        .padding(3)
        .background(style.segmentBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func segment(_ title: String, _ m: CalendarMode) -> some View {
        let on = mode == m
        return Button { setMode(m) } label: {
            Text(title)
                .font(Typography.font(14, weight: .bold))
                .foregroundStyle(on ? style.ink : style.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: on ? Color.black.opacity(0.08) : .clear, radius: 3, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // One chip per child, each centred over that child's column of the
    // split day grid, so the chips are also the columns' names. (The header
    // this sits in is inset 16 on each side; the grid isn't.)
    private var childChips: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColW - 16, height: 1)
            ForEach(visiblePeople) { p in
                chip(id: p.id, name: p.name, color: p.color, symbol: nil)
                    .frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: gridTrailing - 16, height: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }

    // A child's chip is a toggle: tap to show only that child, tap again to
    // show everyone. With none picked, every child is shown.
    private func chip(id: String?, name: String, color: Color, symbol: String?) -> some View {
        let on = focusedChildId == id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { focusedChildId = on ? nil : id }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 24, height: 24)
                    .overlay {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(String(name.prefix(1))).font(Typography.font(11, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                Text(name)
                    .font(Typography.font(14, weight: .semibold))
                    .padding(.trailing, 4)
            }
            .foregroundStyle(style.ink)
            .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 5)
            // Picked: a soft wash of the child's own colour and a ring of it,
            // not a dark fill.
            .background(on ? color.opacity(0.16) : style.segmentBg)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(on ? color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Month drop-down

    private var monthPanel: some View {
        MonthPicker(selectedDay: selectedDay, eventsByDay: eventsByDay, onPickDay: { y, m, d in
            setMonthOpen(false)
            onPickDate(y, m, d)
        })
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 14)
        .background(Color.white)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
    }

    // Steps a day (or a week) at a time, crossing into the neighboring
    // month and loading its real data once it runs past either edge of
    // the loaded month.
    private func stepDay(by delta: Int) {
        lastMotion = Date()
        slideForward = delta > 0
        let next = selectedDay + delta
        if next < 1 {
            var y = CalendarData.dataYear, m = CalendarData.dataMonth - 1
            if m < 1 { m = 12; y -= 1 }
            Task {
                await AppSync.shared.loadCalendarMonth(year: y, month: m)
                withAnimation(Self.pageSpring) { selectedDay = max(1, CalendarData.daysInDataMonth + next); pageDrag = 0 }
            }
        } else if next > CalendarData.daysInDataMonth {
            var y = CalendarData.dataYear, m = CalendarData.dataMonth + 1
            if m > 12 { m = 1; y += 1 }
            let overflow = next - CalendarData.daysInDataMonth
            Task {
                await AppSync.shared.loadCalendarMonth(year: y, month: m)
                withAnimation(Self.pageSpring) { selectedDay = min(overflow, CalendarData.daysInDataMonth); pageDrag = 0 }
            }
        } else {
            withAnimation(Self.pageSpring) { selectedDay = next; pageDrag = 0 }
        }
    }

    // From the week: straight into one day.
    private func openDay(_ day: Int) {
        slideForward = true
        selectedDay = day
        setMode(.day)
    }

    // MARK: Day

    // The days of the loaded month side by side in the system's own paging
    // scroll view, as Google Calendar and Photos do: iOS tells a sideways
    // swipe from a scroll itself, with its own physics, so the two never
    // fight. A blank page past each end of the month loads the month next
    // to it.
    private var dayPager: some View {
        let last = CalendarData.daysInDataMonth
        // Each page sized to the visible area exactly: sized by the scroll
        // view instead, the pages sat too high, under the header.
        return GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(0...(last + 1), id: \.self) { d in
                        Group {
                            if d >= 1 && d <= last { dayPage(d) } else { style.pageBg }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(d)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $pagerDay)
        }
        .onAppear { pagerDay = selectedDay }
        // The day changed from elsewhere (the month picker, back to today,
        // a new day at midnight): the pager follows.
        .onChange(of: selectedDay) { _, d in
            guard pagerDay != d else { return }
            withAnimation(.snappy(duration: 0.3)) { pagerDay = d }
        }
        .onChange(of: pagerDay) { _, d in
            guard let d else { return }
            if d == 0 { stepDay(by: -1) }
            else if d == last + 1 { stepDay(by: 1) }
            else if d != selectedDay { selectedDay = d }
        }
        // A new month is a new set of pages, opened on the selected day.
        .id("\(CalendarData.dataYear)-\(CalendarData.dataMonth)")
    }

    private func dayPage(_ day: Int) -> some View {
        // The real bottom safe area (tab bar, home indicator and the FAB's
        // inset), read outside the ScrollView: content inside one has no
        // safe-area edges of its own to measure.
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        tasksCard(day)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        // With several children the grid is split, one column
                        // each, under the children's chips at the top.
                        grid(day)
                            .padding(.top, 6)
                            .padding(.bottom, outerGeo.safeAreaInsets.bottom)
                    }
                }
                .onChange(of: isActive) { _, active in
                    if active { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
    }

    // One line on the page: how many of the day's tasks are still to do
    // (green "All done" when none are). A tap opens the list.
    private func tasksCard(_ day: Int) -> some View {
        let dayTasks = dayTasks(day)
        let open = dayTasks.filter { $0.event.taskState != .done }.count
        return Button {
            onShowTasks(day, activePeople.map(\.id))
        } label: {
            HStack(spacing: 10) {
                Text("Tasks")
                    .font(style.title(15))
                    .foregroundStyle(style.ink)
                Spacer()
                if dayTasks.isEmpty {
                    Text("None")
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(style.inkSoft)
                } else {
                    Text(open == 0 ? "All done" : "\(open) to do")
                        .font(Typography.font(12.5, weight: .bold))
                        .foregroundStyle(open == 0 ? Color(hex: "25924A") : style.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(open == 0 ? Color(hex: "25924A").opacity(0.12) : style.segmentBg)
                        .clipShape(Capsule())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(style.inkSoft)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(style.cardLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dayTasks.isEmpty)
        .accessibilityHint(dayTasks.isEmpty ? "" : "Shows the list")
        .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
    }

    private func grid(_ day: Int) -> some View {
        let rangeStartY = rangeStartY(day)
        let gridHeight = timeToY(rangeEndHour) - rangeStartY
        return GeometryReader { geo in
            let trackWidth = geo.size.width - timeColW - gridTrailing
            let laidOut = layoutDayEvents(filteredEvents(day).filter { $0.event.category != "Task" }, lanes: activePeople)
            ZStack(alignment: .topLeading) {
                ForEach(hours(day), id: \.self) { h in
                    HStack(spacing: 0) {
                        Text(fmtHour(h))
                            .font(Typography.font(10, weight: .semibold))
                            .foregroundStyle(style.inkSoft)
                            .frame(width: timeColW, alignment: .trailing)
                            .padding(.trailing, 8)
                        Rectangle().fill(style.line).frame(maxWidth: .infinity).frame(height: 0.5)
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .offset(y: timeToY(h) - 6 - rangeStartY)
                }

                // Vertical rules between lanes — a lane's column is
                // otherwise only implied by where its blocks sit.
                if activePeople.count > 1 {
                    ForEach(1..<activePeople.count, id: \.self) { i in
                        Rectangle().fill(style.line).frame(width: 0.5, height: gridHeight)
                            .offset(x: timeColW + trackWidth * CGFloat(i) / CGFloat(activePeople.count))
                    }
                }

                ForEach(laidOut) { item in
                    eventBlock(item, trackWidth: trackWidth, startY: rangeStartY)
                }

                if showNowLine(day) {
                    HStack(spacing: 0) {
                        Circle().fill(Color(hex: "E0483F")).frame(width: 8, height: 8)
                        Rectangle().fill(Color(hex: "E0483F")).frame(width: trackWidth, height: 2)
                    }
                    .offset(x: timeColW - 4, y: timeToY(nowMinutes / 60, nowMinutes % 60) - rangeStartY - 4)
                    .zIndex(100)
                }
            }
        }
        .frame(height: gridHeight)
    }

    // MARK: Week

    // The selected day and the six after it, within the loaded month (the
    // calendar holds one month of data at a time).
    private var weekDays: [Int] {
        Array(selectedDay...min(selectedDay + 6, CalendarData.daysInDataMonth))
    }

    private func weekItems(_ day: Int) -> [CalDayEvent] {
        items(for: day).sorted { a, b in
            let aTask = a.event.category == "Task", bTask = b.event.category == "Task"
            let aAny = aTask && a.event.isAnytime, bAny = bTask && b.event.isAnytime
            if aAny != bAny { return aAny }
            let am = CalendarData.minutesSinceMidnight(a.event.start), bm = CalendarData.minutesSinceMidnight(b.event.start)
            if am != bm { return am < bm }
            if aTask != bTask { return aTask }
            return a.event.title.localizedCaseInsensitiveCompare(b.event.title) == .orderedAscending
        }
    }

    private var weekPage: some View {
        GeometryReader { outerGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(weekDays, id: \.self) { d in weekDaySection(d) }
                    if weekDays.count < 7 {
                        Text("The rest of the week is in \(CalendarData.monthFull[CalendarData.dataMonth % 12]). Swipe to go on.")
                            .font(Typography.font(13, weight: .medium))
                            .foregroundStyle(style.inkSoft)
                    }
                }
                .padding(16)
                .padding(.bottom, outerGeo.safeAreaInsets.bottom)
            }
        }
    }

    private func weekDaySection(_ day: Int) -> some View {
        let today = day == CalendarData.dataDay && CalendarData.isDisplayingCurrentMonth
        let dayItems = weekItems(day)
        return VStack(alignment: .leading, spacing: 8) {
            Button { openDay(day) } label: {
                HStack(spacing: 10) {
                    Text("\(CalendarData.dayNames[day] ?? ""), \(CalendarData.monthShort) \(day)")
                        .font(style.title(16))
                        .foregroundStyle(today ? style.ink : style.inkSoft)
                    if today {
                        Text("TODAY")
                            .font(Typography.font(10, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(style.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Rectangle().fill(style.cardLine).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this day")

            // An empty day is just its heading.
            ForEach(dayItems) { de in weekRow(de) }
        }
    }

    private func weekRow(_ de: CalDayEvent) -> some View {
        let ev = de.event
        let p = CalendarData.person(ev.personId)
        let isTask = ev.category == "Task"
        let isDone = isTask && ev.taskState == .done
        let open = {
            if isTask && !style.readOnly {
                if ev.linkedTaskId != nil { onEditTask(de) } else { onShowTasks(de.day, [ev.personId]) }
            } else {
                onSelect(de)
            }
        }
        // A tap, not a Button, so a swipe between weeks that ends on a row
        // never opens it.
        return Group {
            HStack(spacing: 10) {
                if isTask {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(p.color)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ev.planStatus == .approved ? p.color : p.color.opacity(0.35))
                        .frame(width: 4, height: 20)
                        .frame(width: 18)
                }
                Text(ev.title)
                    .font(Typography.font(14.5, weight: .bold))
                    .foregroundStyle(ev.planStatus == .declined ? style.inkSoft : style.ink)
                    .strikethrough(isDone || ev.planStatus == .declined)
                    .lineLimit(1)
                if !isTask && ev.planStatus != .approved {
                    Text(ev.planStatus == .declined ? "Not this one" : (style.readOnly ? "Waiting" : "Plan"))
                        .font(Typography.font(10.5, weight: .bold))
                        .foregroundStyle(ev.planStatus == .declined ? style.inkSoft : p.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((ev.planStatus == .declined ? style.line : p.color).opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 8)
                Text(isTask ? (ev.isAnytime ? "Task" : "Due \(ev.start)") : "\(ev.start) – \(ev.end)")
                    .font(Typography.font(12, weight: .medium))
                    .foregroundStyle(style.inkSoft)
                    .lineLimit(1)
                if showsOwner {
                    Circle().fill(p.color).frame(width: 22, height: 22)
                        .overlay(Text(String(p.name.prefix(1))).font(Typography.font(10, weight: .bold)).foregroundStyle(.white))
                        .accessibilityLabel(p.name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(style.cardLine, lineWidth: 1))
            .opacity(isDone ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .onTapGesture { if pageIsStill { open() } }
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if !isTask {
                Button { openDay(de.day) } label: { Label("Open this day", systemImage: "calendar") }
                if !style.readOnly {
                    Button { onEditEvent(de) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { onDeleteEvent(de) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    // One event on the grid, in its child's lane (or a sub-column of it
    // when events overlap), in the child's colour.
    private func eventBlock(_ item: LaidOutEvent, trackWidth: CGFloat, startY rangeStartY: CGFloat) -> some View {
        let ev = item.dayEvent.event
        let p = CalendarData.person(ev.personId)
        let laneWidth = trackWidth / CGFloat(item.numCols)
        let laneLeft = laneWidth * CGFloat(item.col)
        let subWidth = laneWidth / CGFloat(item.laneNumCols)
        let subLeft = subWidth * CGFloat(item.laneCol)
        let w = max(subWidth - 6, 24)
        let plan = ev.planStatus
        return HStack(spacing: 4) {
            if plan == .proposed {
                Image(systemName: "hourglass").font(.system(size: 9, weight: .bold))
            } else if plan == .declined {
                Image(systemName: "xmark.circle").font(.system(size: 9, weight: .bold))
            }
            Text(ev.title)
                .font(Typography.font(11, weight: .heavy))
                .strikethrough(plan == .declined)
                .lineLimit(1)
        }
        .foregroundStyle(plan == .approved ? Color.white : (plan == .proposed ? p.color : style.inkSoft))
        .padding(.horizontal, 7)
        .padding(.top, item.height > 40 ? 7 : 4)
        // Inset a point top and bottom, so back-to-back events show a
        // hairline gap instead of merging into one block.
        .frame(width: w, height: max(item.height - 2, 12), alignment: .topLeading)
        .background(plan == .approved ? p.color : (plan == .proposed ? p.color.opacity(0.13) : style.line.opacity(0.5)))
        .overlay {
            if plan == .proposed {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(p.color.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A tap, not a Button: a Button still fired when a finger sliding
        // between days lifted on an event, opening it by accident. A tap is
        // cancelled the moment the finger moves.
        .onTapGesture { if pageIsStill { onSelect(item.dayEvent) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // Long-press to edit or delete without opening the detail first.
        .contextMenu {
            if !style.readOnly {
                Button { onEditEvent(item.dayEvent) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { onDeleteEvent(item.dayEvent) } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .offset(x: timeColW + laneLeft + subLeft + 3, y: item.top - rangeStartY + 1)
        .zIndex(1)
    }
}

// MARK: - Month picker

// The drop-down under the calendar's month title: a Sunday-first month
// grid. Arrows or a sideways swipe page through months; picking a day hands
// (year, month, day) back, and the caller loads that month first if it
// isn't the one loaded (AppSync.loadCalendarMonth). Dots under a day, one
// per child with something on it: live for the loaded month; for any other
// month, worked out from the repeat rules when it's shown
// (AppSync.monthDots), with the last known dots in the meantime.
private struct MonthPicker: View {
    var selectedDay: Int
    var eventsByDay: [Int: [CalEvent]]
    var onPickDay: (Int, Int, Int) -> Void

    @State private var displayedYear = CalendarData.dataYear
    @State private var displayedMonth = CalendarData.dataMonth
    // Dots for months other than the loaded one, as they arrive.
    @State private var otherMonthDots: [String: [Int: [String]]] = CalendarData.monthDots
    private var displayedKey: String { CalendarData.monthKey(displayedYear, displayedMonth) }

    private var cells: [Int?] { CalendarData.monthGrid(year: displayedYear, month: displayedMonth) }
    private var isLoadedMonth: Bool { displayedYear == CalendarData.dataYear && displayedMonth == CalendarData.dataMonth }
    private var isTodayMonth: Bool { displayedYear == CalendarData.todayYear && displayedMonth == CalendarData.todayMonth }

    // Up to four dots, one per child with something on that day.
    private func dotColors(for day: Int) -> [Color] {
        var ids: [String] = []
        if isLoadedMonth {
            for de in CalendarData.expandedEvents(for: day, in: eventsByDay) where !ids.contains(de.event.personId) {
                ids.append(de.event.personId)
            }
        } else {
            ids = otherMonthDots[displayedKey]?[day] ?? []
        }
        return ids.prefix(4).map { CalendarData.person($0).color }
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
                    .font(Typography.font(16, weight: .heavy))
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
            .task(id: displayedKey) {
                guard !isLoadedMonth else { return }
                let dots = await AppSync.shared.monthDots(year: displayedYear, month: displayedMonth)
                CalendarData.monthDots[displayedKey] = dots
                otherMonthDots[displayedKey] = dots
            }
            // A sideways swipe on the grid pages the month.
            .highPriorityGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -40 { shiftMonth(by: 1) }
                        else if value.translation.width > 40 { shiftMonth(by: -1) }
                    }
            )
        }
        .padding(.top, 6)
        .background(Color.white)
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
        let isToday = isTodayMonth && d == CalendarData.dataDay
        let isSel = isLoadedMonth && d == selectedDay && !isToday
        let isPickable = d != nil

        Button {
            if let d { onPickDay(displayedYear, displayedMonth, d) }
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let d {
                        Text("\(d)")
                            .font(Typography.font(16, weight: isToday ? .heavy : .semibold))
                            .foregroundStyle(isToday ? .white : EColor.onSurface)
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
    // Set for a kid's plan waiting on the parent.
    var onApprove: (() -> Void)?
    var onDecline: ((String) -> Void)?

    @State private var editing = false
    @State private var draft: CalEvent
    @State private var showDecline = false
    @State private var declineNote = ""
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

    init(dayEvent: CalDayEvent, startEditing: Bool = false, onSave: @escaping (CalEvent) -> Void, onDelete: @escaping () -> Void, onClose: @escaping () -> Void,
         onApprove: (() -> Void)? = nil, onDecline: ((String) -> Void)? = nil) {
        self.dayEvent = dayEvent
        _editing = State(initialValue: startEditing)
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        self.onApprove = onApprove
        self.onDecline = onDecline
        _draft = State(initialValue: dayEvent.event)
        _startTime = State(initialValue: Self.parseClock(dayEvent.event.start, fallback: Date()))
        _endTime = State(initialValue: Self.parseClock(dayEvent.event.end, fallback: Date().addingTimeInterval(3600)))
    }

    private var person: FamilyPerson { CalendarData.person(dayEvent.event.personId) }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    private var dateLabel: String {
        let name = CalendarData.dayNames[dayEvent.day] ?? ""
        let full = CalendarData.fullDayNames[name] ?? name
        return "\(full), \(CalendarData.monthFull[CalendarData.dataMonth - 1]) \(dayEvent.day)"
    }

    var body: some View {
        Group {
            // Editing uses the same FormShell as adding an event; viewing
            // has its own read-only layout.
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
                    saveLabel: onApprove == nil ? "Save changes" : "Save & approve",
                    onDelete: { showDeleteConfirm = true }
                ) {
                    editFields
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    ScrollView { viewContent }
                        .scrollDismissesKeyboard(.interactively)
                        .dismissKeyboardOnTap()
                    if onApprove != nil { planAnswerBar }
                }
                .background(EColor.surface)
            }
        }
        // Mid-edit, a swipe down would throw away what was typed.
        .alert("Delete \"\(dayEvent.event.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Not this one?", isPresented: $showDecline) {
            TextField("A note for \(person.name) (optional)", text: $declineNote)
            Button("Send") { onDecline?(declineNote.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(person.name) will see this plan marked \"Not this one\", with your note.")
        }
    }

    // A kid's plan waiting on the parent: say no, or approve it onto the
    // calendar. Edit (the pencil) saves and approves together.
    private var planAnswerBar: some View {
        HStack(spacing: 12) {
            Button { declineNote = ""; showDecline = true } label: {
                Text("Not this one")
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(EColor.onSurface)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Button { onApprove?() } label: {
                Label("Approve", systemImage: "checkmark")
                    .font(Typography.font(15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color(hex: "25924A"), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // FormShell's header look, with edit and delete instead of save.
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

    // The same fields Add Event asks for, shown read-only in the form's
    // style.
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
                .padding(.bottom, onApprove == nil ? 20 : 12)

            if onApprove != nil {
                Label("\(person.name)'s plan · waiting for you", systemImage: "hourglass")
                    .font(Typography.font(13, weight: .bold))
                    .foregroundStyle(person.color)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(person.color.opacity(0.12), in: Capsule())
                    .padding(.bottom, 20)
            }

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

// The real task behind a calendar row, with its due moment taken from
// the calendar rather than Home's copy: Home only knows today's time,
// and a task on another day would otherwise lose its deadline in the
// form. A task not synced yet has nothing to edit.
@MainActor
fileprivate func calendarEditableTask(_ de: CalDayEvent) -> ChildTask? {
    guard let id = de.event.linkedTaskId,
          var task = TaskStore.tasks(for: de.event.personId).first(where: { $0.id == id }) else { return nil }
    task.title = de.event.title
    task.description = de.event.note
    task.repeats = de.event.repeats
    if de.event.isAnytime {
        task.dueDate = nil
        task.dueLabel = nil
    } else {
        task.dueDate = CalendarData.date(day: de.originDay, minutes: CalendarData.minutesSinceMidnight(de.event.start))
        task.dueLabel = de.event.start
    }
    return task
}

// MARK: - Day tasks sheet

// Which day's tasks the sheet shows, and whose.
struct TasksSheetTarget: Identifiable {
    var day: Int
    var personIds: [String]
    var id: String { "\(day)|\(personIds.joined(separator: ","))" }
}

// The day's tasks as a list, opened from the calendar's Tasks line (or a
// task in Week). Tasks with no set time first, then a Deadlines section
// with each task's time, earliest first. The parent's version has a pencil
// on each row to edit it; reviewing happens from Home. The kid's version
// (`readOnly`) only shows.
struct DayTasksSheet: View {
    // Whose tasks: one child, or every child shown when "All" is picked.
    var people: [FamilyPerson]
    var tasks: [CalDayEvent]
    var readOnly = false
    var onSaveTask: (ChildTask, String) -> Void = { _, _ in }
    var onDeleteTask: (ChildTask, String) -> Void = { _, _ in }
    var onClose: () -> Void

    @State private var editingTask: ChildTask?
    @State private var editingPersonId = ""

    private var anytime: [CalDayEvent] { tasks.filter { $0.event.isAnytime } }
    private var deadlines: [CalDayEvent] {
        tasks.filter { !$0.event.isAnytime }
            .sorted { CalendarData.minutesSinceMidnight($0.event.start) < CalendarData.minutesSinceMidnight($1.event.start) }
    }
    private var openCount: Int { tasks.filter { $0.event.taskState != .done }.count }

    private var title: String {
        if readOnly { return "My tasks" }
        return people.count == 1 ? "\(people[0].name)'s tasks" : "Tasks"
    }

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

            Text(title)
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(anytime) { de in taskRow(de, due: nil) }
                    if !deadlines.isEmpty {
                        deadlineHeader
                            .padding(.top, anytime.isEmpty ? 0 : 18)
                        ForEach(deadlines) { de in taskRow(de, due: de.event.start) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color.white)
        .sheet(item: $editingTask) { task in
            Group {
            EditTaskReviewSheet(
                task: task,
                onSave: { updated in
                    onSaveTask(updated, editingPersonId)
                    editingTask = nil
                },
                onDelete: {
                    // The sheet slides away first, then the task leaves.
                    let personId = editingPersonId
                    editingTask = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + TaskEdits.sheetCloseDelay) {
                        onDeleteTask(task, personId)
                    }
                },
                onCancel: { editingTask = nil }
            )
            .presentationDetents([.large])
        }
            .presentationDragIndicator(.visible)
        }
    }

    private func editButton(_ de: CalDayEvent) -> some View {
        Button {
            editingPersonId = de.event.personId
            editingTask = calendarEditableTask(de)
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FormGreen.accent)
                .frame(width: 30, height: 30)
                .background(FormGreen.accent.opacity(0.12))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(de.event.title)")
    }

    private var deadlineHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .bold))
            Text("DEADLINES")
                .font(Typography.font(12, weight: .heavy))
                .tracking(1.6)
            Rectangle()
                .fill(FormGreen.accent.opacity(0.25))
                .frame(height: 1)
        }
        .foregroundStyle(FormGreen.accent)
        .padding(.bottom, 2)
    }

    private func statusMeta(_ ev: CalEvent) -> (label: String, tone: Color) {
        switch ev.taskState {
        case .done:
            return (readOnly ? "Done" : "Approved", Color(hex: "25924A"))
        case .submitted:
            return readOnly ? ("Waiting for a grown-up to check", Color(hex: "2563EB"))
                            : ("Awaiting your review", Color(hex: "B26A00"))
        case .pending:
            return (readOnly ? "To do" : "Waiting on \(CalendarData.person(ev.personId).name)", EColor.onSurfaceVariant)
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

    // The due time, small: a lock and the clock time in the child's colour,
    // green once approved.
    private func duePill(_ ev: CalEvent) -> some View {
        let tint = ev.taskState == .done ? Color(hex: "25924A") : CalendarData.person(ev.personId).color
        return HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .bold))
            Text(ev.start).font(Typography.font(11, weight: .heavy))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private func taskRow(_ de: CalDayEvent, due: String?) -> some View {
        let ev = de.event
        let meta = statusMeta(ev)
        return HStack(spacing: 12) {
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
            if due != nil {
                duePill(ev)
            }
            if !readOnly, ev.linkedTaskId != nil {
                editButton(de)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Add event

// The calendar's + : first asks Task or Event, then shows that form. Both
// land on the day open in the calendar and are saved by ScreenCalendar's
// createItem (a real task or event for the chosen child).
private struct AddCalendarSheet: View {
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void

    private enum Kind: Equatable { case task, event }
    @State private var kind: Kind?
    // Small for the Task/Event choice, full height for a form. Both
    // detents stay allowed; changing the selection is what animates the
    // sheet to the new height.
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
        // The Task/Event choice is small; either form is full height.
        // One height at a time: the small choice, or the full form. With
        // both allowed, a drag down could leave the form half-collapsed
        // instead of closing it.
        .presentationDetents(kind == nil ? [.height(340)] : [.large], selection: $detentSelection)
        .presentationDragIndicator(.visible)
        // Solid, like Home's sheet: at a partial height iOS would otherwise
        // draw the sheet as see-through glass.
        .presentationBackground(EColor.surface)
        .onChange(of: kind) { _, newValue in
            detentSelection = newValue == nil ? .height(340) : .large
        }
        // A drag down on the grab line closes it at any step.
    }

    // FormShell's own chrome (close button, big bold title) instead
    // of a system nav bar, so this first step reads as the same sheet as
    // whichever form comes after it, not a different screen bolted on
    // front. Two plain tiles, icon and label only — no description text,
    // no card border, no chevron. What a task vs. an event *is* belongs
    // in the form each one opens, not a sentence here to read first.
    private var kindPicker: some View {
        // No close button: tapping outside or dragging down closes it. The
        // heading and tiles sit centred in the sheet, equal space around.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text("Add to Calendar")
                .font(Typography.font(26, weight: .heavy))
                .foregroundStyle(FormGreen.title)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            HStack(spacing: 14) {
                kindTile(title: "Task", systemImage: "checkmark.circle.fill") { kind = .task }
                kindTile(title: "Event", systemImage: "calendar") { kind = .event }
            }
            .padding(.horizontal, 20)
            // A touch above true centre.
            .padding(.bottom, 16)

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

// Add Event: title, which child (when there's more than one), start and
// end times, repeats, notes. It lands on the day open in the calendar.
private struct AddCalendarEventForm: View {
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void
    var onCancel: () -> Void

    // Every event is a child's: the selected child by default.
    @State private var personId = SessionManager.shared.activeChildId ?? FamilyStore.children.first?.id ?? ""
    @State private var title = ""
    // Starts at the next half-hour, for an hour.
    @State private var startTime: Date = AddCalendarEventForm.roundedToNextHalfHour(Date())
    @State private var endTime: Date = AddCalendarEventForm.roundedToNextHalfHour(Date()).addingTimeInterval(3600)
    // Not asked for; every event saves as "Activity".
    private let category = "Activity"
    @State private var repeatDays: Set<String> = []
    @State private var note = ""
    @Environment(\.scrollFormToBottom) private var scrollFormToBottom

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
                location: "", note: note.trimmingCharacters(in: .whitespacesAndNewlines), repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ",")
            ), currentDay)
        }, canSave: canSave, saveLabel: "Add event") {
            FormField(label: "Title") {
                FormTextField(placeholder: "e.g. Piano Practice", text: $title, scrollToTopOnFocus: true)
            }
            // Only a question when there's more than one child; with one,
            // the event is simply theirs.
            if CalendarData.people.count > 1 {
                FormField(label: "For") {
                    FlowChips {
                        ForEach(CalendarData.people) { p in
                            DotChip(label: p.name, color: p.color, selected: personId == p.id) { personId = p.id }
                        }
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
            // Tucked away like Add Task's extras: optional, so out of sight
            // until wanted.
            MoreOptions {
                FormField(label: "Description") {
                    TextField("Add details…", text: $note, axis: .vertical)
                        .font(Typography.font(15, weight: .regular))
                        .lineLimit(3...5)
                        .padding(14)
                        .background(FormGreen.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        // Growing a line while typing keeps it above the keyboard.
                        .onChange(of: note) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scrollFormToBottom() }
                        }
                }
            }
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
    // The day open on the calendar: the task always lands on it, the same
    // way Home's Add Task uses its Today / Tomorrow tab. No date picker.
    var currentDay: Int
    var onCreate: (CalEvent, Int) -> Void
    var onCancel: () -> Void

    @State private var personId = SessionManager.shared.activeChildId ?? FamilyStore.children.first?.id ?? ""
    @State private var title = ""
    @State private var whatToDo = ""
    // A deadline is only a time on that day (More options); without one
    // the task is anytime that day.
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var repeatDays: Set<String> = []

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }


    var body: some View {
        AddTaskFormFields(
            title: "Add Task", saveLabel: "Add task", fixedChild: nil,
            taskTitle: $title, personId: $personId, whatToDo: $whatToDo, repeatDays: $repeatDays,
            hasDeadline: $hasDeadline, deadline: $deadline, day: CalendarData.date(day: currentDay),
            canSave: canSave, onCancel: onCancel, onSave: {
                let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
                onCreate(CalEvent(
                    personId: personId, title: title, emoji: emojiForCalendarCategory("Task"),
                    start: hasDeadline ? ChildRule.fmtClock(deadline) : "12:00 AM",
                    end: hasDeadline ? ChildRule.fmtClock(deadline.addingTimeInterval(1800)) : "12:00 AM",
                    category: "Task", location: "", note: whatToDo.trimmingCharacters(in: .whitespaces),
                    repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ","),
                    isAnytime: !hasDeadline
                ), currentDay)
            }
        )
    }
}
