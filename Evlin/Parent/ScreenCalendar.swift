import SwiftUI

// Ported from Evlin_Parent_view/index.html's ScreenCalendar — a real Day
// timeline / Month grid / Schedule agenda calendar (not a flat event list),
// with a shared overlap-layout algorithm for same-day events and a detail
// sheet that toggles between view and edit modes.

private let hourHeight: CGFloat = 56
private let startHour = 0
private let endHour = 24
private let timeColW: CGFloat = 46

private func timeToY(_ h: Int, _ m: Int = 0) -> CGFloat {
    CGFloat(h - startHour) * hourHeight + CGFloat(m) / 60 * hourHeight
}

private func evTop(_ start: String) -> CGFloat {
    let mins = CalendarData.minutesSinceMidnight(start)
    return timeToY(mins / 60, mins % 60)
}

private func fmtHour(_ h: Int) -> String {
    if h == 0 || h == 24 { return "" }
    if h == 12 { return "12 PM" }
    return h < 12 ? "\(h) AM" : "\(h - 12) PM"
}

private struct LaidOutEvent: Identifiable {
    var id: UUID
    var dayEvent: CalDayEvent
    var top: CGFloat
    var height: CGFloat
    var col: Int
    var numCols: Int
}

// Every person gets a permanently-assigned lane spanning the whole day, in
// the same left-to-right order as the avatar row above the timeline — not
// just splitting width when two people happen to overlap in time. That used
// to mean a non-overlapping event (the common case: most of a family's
// events don't collide) rendered full-width, with nothing to visually tie
// it to "this is Emma's lane" the way the header row implies. Now Emma's
// events always sit under Emma's avatar, whether or not anyone else has
// something scheduled at the same time.
private func layoutDayEvents(_ events: [CalDayEvent], lanes: [FamilyPerson]) -> [LaidOutEvent] {
    let numCols = max(lanes.count, 1)
    return events.compactMap { de -> LaidOutEvent? in
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
}

struct ScreenCalendar: View {
    @State private var selectedDay = CalendarData.dataDay
    @State private var showDatePicker = false
    @State private var eventsByDay: [Int: [CalEvent]] = CalendarData.eventsByDay
    @State private var activeDayEvent: CalDayEvent?
    @State private var showAddEvent = false

    // Children only — a parent doesn't have chores that gate screen time,
    // so a "Family" lane sat empty most days while still costing a full
    // quarter of the grid's width. Family-wide events (still real,
    // still timed) show as their own compact strip above the lanes
    // instead of occupying one.
    private var lanePeople: [FamilyPerson] { CalendarData.people.filter { $0.id != "family" } }

    private func expandedEvents(for day: Int) -> [CalDayEvent] {
        CalendarData.expandedEvents(for: day, in: eventsByDay)
    }

    var body: some View {
        NavigationStack {
            DayTimelineView(
                selectedDay: $selectedDay,
                visiblePeople: lanePeople,
                events: expandedEvents(for: selectedDay),
                onSelect: { activeDayEvent = $0 },
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
            // Two different sheets, not one form that hides fields — a task
            // opens to an Approve action, an event opens to edit/delete.
            Group {
                if de.event.category == "Task" {
                    TaskDetailSheet(dayEvent: de, onApprove: {
                        if let i = eventsByDay[de.originDay]?.firstIndex(where: { $0.id == de.event.id }) {
                            eventsByDay[de.originDay]?[i].taskState = .done
                        }
                        activeDayEvent = nil
                    }, onDelete: {
                        eventsByDay[de.originDay]?.removeAll { $0.id == de.event.id }
                        activeDayEvent = nil
                    }, onClose: { activeDayEvent = nil })
                } else {
                    EventDetailSheet(dayEvent: de, onSave: { updated in
                        if let i = eventsByDay[de.originDay]?.firstIndex(where: { $0.id == de.event.id }) {
                            eventsByDay[de.originDay]?[i] = updated
                        }
                        activeDayEvent = nil
                    }, onDelete: {
                        eventsByDay[de.originDay]?.removeAll { $0.id == de.event.id }
                        activeDayEvent = nil
                    }, onClose: { activeDayEvent = nil })
                }
            }
        }
        .sheet(isPresented: $showAddEvent) {
            AddCalendarSheet(onCreate: { ev in
                eventsByDay[selectedDay, default: []].append(ev)
                showAddEvent = false
            }, onCancel: { showAddEvent = false })
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showDatePicker) {
            MonthPickerSheet(selectedDay: selectedDay, onPickDay: { d in
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
    var events: [CalDayEvent]
    var onSelect: (CalDayEvent) -> Void
    var onOpenDatePicker: () -> Void

    private var filteredEvents: [CalDayEvent] {
        let ids = Set(visiblePeople.map(\.id))
        return events.filter { ids.contains($0.event.personId) }
    }

    private var familyEvents: [CalDayEvent] {
        events.filter { $0.event.personId == "family" }.sorted { evTop($0.event.start) < evTop($1.event.start) }
    }

    // The grid's own timed items — events plus due-time tasks, excluding
    // anytime tasks (placeholder start time) and family events (their own
    // strip, not a lane). This same list backs both the default-range
    // extension below and the actual laid-out blocks, so they can't drift
    // apart the way a separately-computed condition could.
    private var timedLaneItems: [CalDayEvent] {
        filteredEvents.filter { !$0.event.isAnytime && $0.event.personId != "family" }
    }

    private func anytimeTasks(for personId: String) -> [CalDayEvent] {
        filteredEvents.filter { $0.event.personId == personId && $0.event.isAnytime }
    }

    private var hasAnytimeTasks: Bool {
        visiblePeople.contains { !anytimeTasks(for: $0.id).isEmpty }
    }

    // 7 AM-9 PM by default, extending only as far as an actual item outside
    // that window requires — not the full 0-24 range, most of which would
    // just be empty scrolling for a typical family day.
    private static let defaultStartHour = 7
    private static let defaultEndHour = 21

    private var rangeStartHour: Int {
        let earliest = timedLaneItems.map { CalendarData.minutesSinceMidnight($0.event.start) / 60 }.min() ?? Self.defaultStartHour
        return max(startHour, min(Self.defaultStartHour, earliest))
    }
    private var rangeEndHour: Int {
        let latestEndMinutes = timedLaneItems.map { CalendarData.minutesSinceMidnight($0.event.end) }.max() ?? (Self.defaultEndHour * 60)
        let latest = (latestEndMinutes + 59) / 60
        return min(endHour, max(Self.defaultEndHour, latest))
    }
    private var rangeStartY: CGFloat { timeToY(rangeStartHour) }
    private var hours: [Int] { Array(rangeStartHour...rangeEndHour) }

    // The real clock's hour, not the mock day's — clamped to the rendered
    // range so scrolling to it never lands outside the grid on a day whose
    // range doesn't cover the current hour.
    private var nowHour: Int {
        min(max(Calendar.current.component(.hour, from: Date()), rangeStartHour), rangeEndHour)
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        // One tick's defer — .scrollTo on the same frame the content first
        // lays out can resolve against the pre-layout geometry and land
        // short.
        DispatchQueue.main.async {
            withAnimation(nil) { proxy.scrollTo("hour-\(nowHour)", anchor: UnitPoint(x: 0, y: 0.33)) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dateBar
            Divider()

            if !familyEvents.isEmpty {
                familyStrip
                Divider()
            }

            laneHeader
            Divider()

            if hasAnytimeTasks {
                anytimeZone
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        let trackWidth = geo.size.width - timeColW
                        let laidOut = layoutDayEvents(filteredEvents, lanes: visiblePeople)
                        ZStack(alignment: .topLeading) {
                            // A normal-flow ruler, invisible, purely so
                            // ScrollViewReader has a real *layout* position
                            // to resolve — everything else in this ZStack is
                            // placed with .offset(), which moves a view
                            // visually without moving the layout frame
                            // .scrollTo actually reads, so none of those
                            // could ever be a reliable scroll target.
                            VStack(spacing: 0) {
                                ForEach(hours, id: \.self) { h in
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

                            ForEach(laidOut) { item in
                                eventBlock(item, trackWidth: trackWidth)
                            }
                        }
                    }
                    .frame(height: timeToY(rangeEndHour) - rangeStartY + 24)
                    // Clears the FAB/tab bar on its own too — the outer
                    // safeAreaInset already keeps content from rendering
                    // underneath them, but a little extra room past the
                    // last hour line reads better than stopping flush.
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToNow(proxy) }
                .onChange(of: selectedDay) { _, _ in scrollToNow(proxy) }
            }
        }
    }

    private var dateBar: some View {
        HStack {
            Button { selectedDay = max(1, selectedDay - 1) } label: { navCircle("chevron.left") }
            Spacer()
            Button(action: onOpenDatePicker) {
                VStack(spacing: 2) {
                    Text("\(CalendarData.dayNames[selectedDay] ?? ""), Sep \(selectedDay)")
                        .font(Typography.font(17, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                    Text(selectedDay == CalendarData.dataDay ? "TODAY" : "TAP TO CHANGE DATE")
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

    private var familyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(familyEvents) { de in
                    Button { onSelect(de) } label: {
                        HStack(spacing: 6) {
                            Text(de.event.emoji).font(.system(size: 12))
                            Text(de.event.title).font(Typography.font(12.5, weight: .bold))
                            Text(de.event.start).font(Typography.font(11, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                        }
                        .foregroundStyle(EColor.onSurface)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(CalendarData.person("family").bg)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    private var laneHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColW)
            ForEach(visiblePeople) { p in
                VStack(spacing: 4) {
                    Circle().fill(p.color).frame(width: 36, height: 36)
                        .overlay(Text(String(p.name.prefix(1))).font(Typography.font(14, weight: .bold)).foregroundStyle(.white))
                    Text(p.name).font(Typography.font(10, weight: .semibold)).foregroundStyle(EColor.onSurface)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            ForEach(visiblePeople) { p in
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

    // Strikethrough (done), a filled dot (submitted, waiting on the
    // parent), or a padlock (gating screen time until approved).
    private func anytimeChip(_ de: CalDayEvent) -> some View {
        let ev = de.event
        let p = CalendarData.person(ev.personId)
        return Button { onSelect(de) } label: {
            HStack(spacing: 5) {
                statusIcon(ev)
                Text(ev.title)
                    .font(Typography.font(11.5, weight: .semibold))
                    .strikethrough(ev.taskState == .done)
                    .lineLimit(1)
            }
            .foregroundStyle(p.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusIcon(_ ev: CalEvent) -> some View {
        switch (ev.taskState, ev.gatesUnlock) {
        case (.done, _):
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
        case (.submitted, _):
            Circle().frame(width: 6, height: 6)
        case (.pending, true):
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
        case (.pending, false):
            EmptyView()
        }
    }

    // "by 5PM" rather than "by 5:00 PM" — condensed to match the chips'
    // own compact type instead of spelling out a full clock time.
    private func shortTime(_ text: String) -> String {
        let parts = text.split(separator: " ")
        guard parts.count == 2 else { return text }
        let hm = parts[0].split(separator: ":")
        guard hm.count == 2 else { return text }
        return hm[1] == "00" ? "\(hm[0])\(parts[1])" : "\(hm[0]):\(hm[1])\(parts[1])"
    }

    // Told apart by shape, not color — a solid fill for an event (it just
    // happens, at a time), a dashed outline for a task (it's owed, by a
    // time).
    private func eventBlock(_ item: LaidOutEvent, trackWidth: CGFloat) -> some View {
        let ev = item.dayEvent.event
        let p = CalendarData.person(ev.personId)
        let isTask = ev.category == "Task"
        let widthFrac = 1 / CGFloat(item.numCols)
        let leftFrac = CGFloat(item.col) / CGFloat(item.numCols)
        let w = max(trackWidth * widthFrac - 6, 24)
        return Button { onSelect(item.dayEvent) } label: {
            VStack(alignment: .leading, spacing: 2) {
                if !isTask, item.height > 38 {
                    Text(ev.emoji).font(.system(size: 11))
                }
                HStack(spacing: 3) {
                    if isTask {
                        statusIcon(ev)
                    } else if ev.repeats != "none" {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    }
                    Text(ev.title)
                        .font(Typography.font(11, weight: .heavy))
                        .strikethrough(isTask && ev.taskState == .done)
                        .lineLimit(1)
                }
                if isTask {
                    Text("by \(shortTime(ev.start))")
                        .font(Typography.font(9.5, weight: .semibold))
                }
            }
            .foregroundStyle(isTask ? p.color : .white)
            .padding(.horizontal, 7)
            .padding(.top, item.height > 40 ? 7 : 4)
            .frame(width: w, height: item.height, alignment: .topLeading)
            .background(isTask ? Color.clear : p.color)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isTask ? p.color : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + trackWidth * leftFrac + 3, y: item.top - rangeStartY)
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
    var onPickDay: (Int) -> Void

    @State private var displayedYear = CalendarData.dataYear
    @State private var displayedMonth = CalendarData.dataMonth

    private var cells: [Int?] { CalendarData.monthGrid(year: displayedYear, month: displayedMonth) }
    private var isDataMonth: Bool { displayedYear == CalendarData.dataYear && displayedMonth == CalendarData.dataMonth }

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
            .frame(maxWidth: .infinity, minHeight: 44)
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

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(EColor.onSurface)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { editing = true } label: { Image(systemName: "pencil").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40) }
                .buttonStyle(.plain)
            Button { showDeleteConfirm = true } label: { Image(systemName: "trash").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.top, 8)
    }

    private var viewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 4).fill(person.color).frame(width: 14, height: 14).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(dayEvent.event.emoji) \(dayEvent.event.title)")
                        .font(Typography.font(22, weight: .heavy)).foregroundStyle(EColor.primary)
                    Text(dateLabel).font(Typography.font(14, weight: .semibold)).foregroundStyle(EColor.onSurface)
                    Text("\(dayEvent.event.start) \u{2013} \(dayEvent.event.end)").font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                }
            }
            .padding(.vertical, 16)

            if dayEvent.event.repeats != "none" {
                infoRow(icon: "arrow.triangle.2.circlepath") {
                    Text(repeatDisplayLabel(dayEvent.event.repeats)).font(Typography.font(14, weight: .regular))
                }
            }
            infoRow(icon: "person.fill") {
                HStack(spacing: 9) {
                    Circle().fill(person.color).frame(width: 24, height: 24)
                        .overlay(Text(String(person.name.prefix(1))).font(Typography.font(11, weight: .bold)).foregroundStyle(.white))
                    Text(person.name).font(Typography.font(14, weight: .semibold))
                    Pill(text: dayEvent.event.category, color: person.color)
                }
            }
            if !dayEvent.event.location.isEmpty {
                infoRow(icon: "mappin.circle.fill") { Text(dayEvent.event.location).font(Typography.font(14, weight: .regular)) }
            }
            infoRow(icon: "bell.fill") {
                HStack {
                    Text("30 minutes before").font(Typography.font(14, weight: .regular))
                    Spacer()
                    EToggle(on: $reminder)
                }
            }
            if !dayEvent.event.note.isEmpty {
                infoRow(icon: "note.text", last: true) { Text(dayEvent.event.note).font(Typography.font(14, weight: .regular)) }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    @ViewBuilder
    private func infoRow<Content: View>(icon: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(EColor.onSurfaceVariant).frame(width: 22)
            content().foregroundStyle(EColor.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { if !last { Divider() } }
    }

    @ViewBuilder
    private var editFields: some View {
        FormField(label: "Title") { FormTextField(placeholder: "Event title", text: $draft.title) }
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

// MARK: - Task detail

// A task opens to an Approve action, not an edit form — its fields (who,
// when, what to do) are the same ones set when it was created and aren't
// meant to change from here; the thing a parent actually does with a task
// on the calendar is review and clear it.
private struct TaskDetailSheet: View {
    var dayEvent: CalDayEvent
    var onApprove: () -> Void
    var onDelete: () -> Void
    var onClose: () -> Void

    @State private var showDeleteConfirm = false

    private var event: CalEvent { dayEvent.event }
    private var person: FamilyPerson { CalendarData.person(event.personId) }

    private var dateLabel: String {
        let name = CalendarData.dayNames[dayEvent.day] ?? ""
        let full = CalendarData.fullDayNames[name] ?? name
        return "\(full), September \(dayEvent.day)"
    }

    private var whenLabel: String {
        event.isAnytime ? "Anytime today" : "Due \(event.start)"
    }

    private var statusLabel: (text: String, color: Color) {
        switch event.taskState {
        case .done: return ("Approved", EColor.secondary)
        case .submitted: return ("Waiting on you", Color(hex: "B26A00"))
        case .pending: return (event.gatesUnlock ? "Not done — locking apps" : "Not done yet", EColor.onSurfaceVariant)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView { content }
        }
        .background(EColor.surface)
        .alert("Delete \"\(event.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.top, 8)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 4).fill(person.color).frame(width: 14, height: 14).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(event.emoji) \(event.title)")
                        .font(Typography.font(22, weight: .heavy)).foregroundStyle(EColor.primary)
                    Text(dateLabel).font(Typography.font(14, weight: .semibold)).foregroundStyle(EColor.onSurface)
                    Text(whenLabel).font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                }
            }
            .padding(.vertical, 16)

            infoRow(icon: "person.fill") {
                HStack(spacing: 9) {
                    Circle().fill(person.color).frame(width: 24, height: 24)
                        .overlay(Text(String(person.name.prefix(1))).font(Typography.font(11, weight: .bold)).foregroundStyle(.white))
                    Text(person.name).font(Typography.font(14, weight: .semibold))
                }
            }
            infoRow(icon: statusIconName) {
                Text(statusLabel.text).font(Typography.font(14, weight: .semibold)).foregroundStyle(statusLabel.color)
            }
            if event.gatesUnlock {
                infoRow(icon: "lock.fill") {
                    Text("Holds \(person.name)'s apps locked until approved.").font(Typography.font(13, weight: .regular))
                }
            }
            if !event.note.isEmpty {
                infoRow(icon: "note.text", last: event.taskState == .done) { Text(event.note).font(Typography.font(14, weight: .regular)) }
            }

            if event.taskState != .done {
                PrimaryButton(title: "Approve", systemIcon: "checkmark") { onApprove() }
                    .padding(.top, 20)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    private var statusIconName: String {
        switch event.taskState {
        case .done: return "checkmark.circle.fill"
        case .submitted: return "circle.fill"
        case .pending: return event.gatesUnlock ? "lock.fill" : "circle"
        }
    }

    @ViewBuilder
    private func infoRow<Content: View>(icon: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(EColor.onSurfaceVariant).frame(width: 22)
            content().foregroundStyle(EColor.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { if !last { Divider() } }
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
    var onCreate: (CalEvent) -> Void
    var onCancel: () -> Void

    private enum Kind { case task, event }
    @State private var kind: Kind?

    var body: some View {
        switch kind {
        case .none:
            kindPicker
        case .event:
            AddCalendarEventForm(onCreate: onCreate, onCancel: { kind = nil })
        case .task:
            AddCalendarTaskForm(onCreate: onCreate, onCancel: { kind = nil })
        }
    }

    private var kindPicker: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("What are you adding?")
                    .font(Typography.font(15, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .padding(.top, 4)

                kindOption(
                    title: "Task",
                    subtitle: "Something for a kid to do and check off, like a chore or homework.",
                    systemImage: "checkmark.circle.fill"
                ) { kind = .task }

                kindOption(
                    title: "Event",
                    subtitle: "Something on the family calendar with a time, like practice or an appointment.",
                    systemImage: "calendar"
                ) { kind = .event }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Add to Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
    }

    private func kindOption(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(EColor.primaryContainer)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: systemImage).font(.system(size: 19, weight: .semibold)).foregroundStyle(EColor.primary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typography.font(16, weight: .bold)).foregroundStyle(EColor.onSurface)
                    Text(subtitle).font(Typography.font(12.5, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(EColor.outline)
            }
            .padding(16)
            .background(EColor.surfaceContainerLowest)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
    var onCreate: (CalEvent) -> Void
    var onCancel: () -> Void

    @State private var personId = CalendarData.people[0].id
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
            ))
        }, canSave: canSave, saveLabel: "Add event") {
            FormField(label: "Title") {
                FormTextField(placeholder: "e.g. Piano Practice", text: $title)
            }
            FormField(label: "For") {
                FlowChips {
                    ForEach(CalendarData.people) { p in
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
    var onCreate: (CalEvent) -> Void
    var onCancel: () -> Void

    @State private var personId = CalendarData.people.first { $0.id != "family" }?.id ?? CalendarData.people[0].id
    @State private var title = ""
    @State private var whatToDo = ""
    // The choice that decides which zone this lands in — the ANYTIME row
    // (no deadline) or a due-time slot on the grid — so it's asked up
    // front rather than inferred from whether a time got picked.
    @State private var isAnytime = true
    @State private var dueTime: Date = AddCalendarTaskForm.roundedToNextHalfHour(Date())
    @State private var repeatDays: Set<String> = []

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func roundedToNextHalfHour(_ date: Date) -> Date {
        let cal = Calendar.current
        let minute = cal.component(.minute, from: date)
        let addMinutes = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(byAdding: .minute, value: addMinutes, to: date) ?? date
    }

    var body: some View {
        FormShell(title: "Add Task", onCancel: onCancel, onSave: {
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            onCreate(CalEvent(
                personId: personId, title: title, emoji: emojiForCalendarCategory("Task"),
                start: isAnytime ? "12:00 AM" : ChildRule.fmtClock(dueTime),
                end: isAnytime ? "12:00 AM" : ChildRule.fmtClock(dueTime.addingTimeInterval(1800)),
                category: "Task", location: "", note: whatToDo.trimmingCharacters(in: .whitespaces),
                repeats: repeatCodes.isEmpty ? "none" : repeatCodes.joined(separator: ","),
                isAnytime: isAnytime
            ))
        }, canSave: canSave, saveLabel: "Add task") {
            FormField(label: "Title") {
                FormTextField(placeholder: "e.g. Make your bed", text: $title)
            }
            FormField(label: "For") {
                FlowChips {
                    ForEach(CalendarData.people.filter { $0.id != "family" }) { p in
                        DotChip(label: p.name, color: p.color, selected: personId == p.id) { personId = p.id }
                    }
                }
            }
            FormField(label: "When") {
                FlowChips {
                    DotChip(label: "Anytime today", color: nil, selected: isAnytime) { isAnytime = true }
                    DotChip(label: "By a set time", color: nil, selected: !isAnytime) { isAnytime = false }
                }
            }
            if !isAnytime {
                FormField(label: "Due") {
                    FormTimeField(date: $dueTime)
                }
            }
            FormField(label: "What to do") {
                TextField("Instructions…", text: $whatToDo, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .lineLimit(2...4)
                    .padding(14)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            RepeatPicker(selectedDays: $repeatDays)
        }
    }
}
