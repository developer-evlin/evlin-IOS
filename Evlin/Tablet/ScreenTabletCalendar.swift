import SwiftUI

// The kid-side day calendar. Read-only — creating/editing events stays a
// parent capability (ScreenCalendar); this is "what do I have today,"
// not a place to manage the family's schedule. Defaults to just this
// kid's own lane, same reasoning as a kid's Task/Ring tabs only ever
// showing their own stuff — opening straight to "everyone's calendar"
// would bury what a kid actually came here to check under siblings'
// piano lessons and a parent's work call. "Whole family" expands it to
// the same multi-lane grid the parent sees, reusing that exact layout
// math (hourHeight/timeToY/layoutDayEvents, made internal in
// ScreenCalendar.swift) so both sides of the app draw an identical
// timeline from identical data, just with their own chrome.
struct ScreenTabletCalendar: View {
    @State private var selectedDay = CalendarData.dataDay
    @State private var showWholeFamily = false
    @State private var selectedEvent: CalDayEvent?

    // "Just me" is a single-lane timeline — reading-shaped content, same
    // as everywhere else in KidAdaptive, so it gets centered in a column
    // rather than stretching one narrow lane across the full iPad width
    // with dead space beside it. "Whole family" is a real multi-lane grid
    // that benefits from the extra width, so it stays uncapped on iPad.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }
    private var calendarMaxWidth: CGFloat? { (kid.isRegular && !showWholeFamily) ? 640 : nil }

    private var selfPerson: FamilyPerson { CalendarData.person(TabletData.child.id) }
    private var lanes: [FamilyPerson] { showWholeFamily ? CalendarData.people : [selfPerson] }

    private var dayEvents: [CalDayEvent] {
        CalendarData.expandedEvents(for: selectedDay, in: CalendarData.eventsByDay)
    }

    private var filteredEvents: [CalDayEvent] {
        let ids = Set(lanes.map(\.id))
        return dayEvents.filter { ids.contains($0.event.personId) }
    }

    // Only meaningful once the whole family is visible — in "just me"
    // mode there's no other lane for a shared block to sit behind.
    private var familyEvents: [CalDayEvent] {
        guard showWholeFamily else { return [] }
        return dayEvents.filter { $0.event.personId == CalendarData.everyone.id }
            .sorted { evTop($0.event.start) < evTop($1.event.start) }
    }

    private func anytimeTasks(for personId: String) -> [CalDayEvent] {
        filteredEvents.filter { $0.event.personId == personId && $0.event.isAnytime }
    }

    private var hasAnytimeTasks: Bool {
        lanes.contains { !anytimeTasks(for: $0.id).isEmpty }
    }

    // Labels/dividers draw one line per boundary, 0 through 24 inclusive.
    private var hours: [Int] { Array(startHour...endHour) }
    // The ScrollViewReader ruler below is anchored against the 24 actual
    // hour *rows* (0:00–0:59 through 23:00–23:59) — one shorter than
    // `hours` above on purpose, matching ScreenCalendar's own DayTimelineView:
    // including a 25th "hour-24" block here made the ruler 24×hourHeight
    // taller than the grid's real content height, and nothing ever scrolls
    // to hour 24.
    private var hourRows: [Int] { Array(startHour..<endHour) }

    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private var showNowLine: Bool { selectedDay == CalendarData.dataDay }
    private var nowHour: Int {
        min(max(Calendar.current.component(.hour, from: Date()), startHour), endHour)
    }

    // Matches ScreenCalendar.DayTimelineView.scrollToNow exactly: a
    // fractional UnitPoint anchor (the old approach here) asks the scroll
    // view to place "now" partway down the viewport, which past a certain
    // hour needs more content *above* now than the day actually has left
    // below the fold to balance it — ScrollView has no headroom to
    // overscroll into, so it clamps and can leave earlier blocks stranded
    // above the visible top edge with no way to scroll up into them.
    // Anchoring flush to the top of the target hour is always satisfiable.
    // One hour earlier than `now`, not `now` itself, so a task due marker's
    // pill (which sits *above* its own due line) doesn't land scrolled
    // just above the very top edge the moment the calendar opens.
    private func scrollToNow(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            let anchorHour = max(startHour, nowHour - 1)
            withAnimation(nil) { proxy.scrollTo("kid-hour-\(anchorHour)", anchor: .top) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(KidTheme.line)

            if lanes.count > 1 {
                laneHeader
                    .frame(height: kid.of(56, 64))
                    .fixedSize(horizontal: false, vertical: true)
                Divider().background(KidTheme.line)
            }

            if hasAnytimeTasks {
                anytimeZone
                Divider().background(KidTheme.line)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        let trackWidth = geo.size.width - timeColW
                        let gridHeight = timeToY(endHour)
                        // Tasks never enter the block/overlap pipeline —
                        // a deadline has no duration to lay out, so only
                        // real events compete for lane width here, same
                        // split ScreenCalendar.DayTimelineView makes.
                        let laidOut = layoutDayEvents(filteredEvents.filter { $0.event.category != "Task" }, lanes: lanes)
                        let dueGroups = groupDueTasks(filteredEvents)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(hourRows, id: \.self) { h in
                                    Color.clear.frame(height: hourHeight).id("kid-hour-\(h)")
                                }
                            }

                            ForEach(hours, id: \.self) { h in
                                HStack(spacing: 0) {
                                    Text(fmtHour(h))
                                        .font(Typography.font(10, weight: .semibold))
                                        .foregroundStyle(KidTheme.inkSoft)
                                        .frame(width: timeColW, alignment: .trailing)
                                        .padding(.trailing, 8)
                                    Rectangle().fill(KidTheme.line).frame(maxWidth: .infinity).frame(height: 0.5)
                                }
                                .frame(width: geo.size.width, alignment: .leading)
                                .offset(y: timeToY(h) - 6)
                            }

                            if lanes.count > 1 {
                                ForEach(1..<lanes.count, id: \.self) { i in
                                    Rectangle().fill(KidTheme.line).frame(width: 0.5, height: gridHeight)
                                        .offset(x: timeColW + trackWidth * CGFloat(i) / CGFloat(lanes.count))
                                }
                            }

                            ForEach(familyEvents) { de in
                                familyBlock(de, trackWidth: trackWidth)
                            }

                            ForEach(laidOut) { item in
                                eventBlock(item, trackWidth: trackWidth)
                            }

                            // Deadlines: a 2pt rule marking the exact
                            // moment, a pill above it to tap — drawn last
                            // (high zIndex) so a marker sits on top of
                            // whatever event happens to run through that
                            // same hour without fighting it for width.
                            // Same dedicated marker treatment as
                            // ScreenCalendar.DayTimelineView.taskDueMarker,
                            // instead of tasks sharing the block/overlap
                            // layout with real events.
                            ForEach(dueGroups) { group in
                                taskDueMarker(group, trackWidth: trackWidth)
                            }

                            if showNowLine {
                                Rectangle().fill(Color(hex: "E0483F")).frame(width: trackWidth, height: 2)
                                    .offset(x: timeColW, y: timeToY(nowMinutes / 60, nowMinutes % 60) - 1)
                                    .zIndex(100)
                            }
                        }
                    }
                    .frame(height: timeToY(endHour) + 24)
                    .padding(.bottom, 100)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToNow(proxy) }
                .onChange(of: selectedDay) { _, _ in scrollToNow(proxy) }
            }
        }
        .kidContentColumn(calendarMaxWidth)
        .background(KidTheme.background)
        .sheet(item: $selectedEvent) { de in
            KidEventDetailSheet(dayEvent: de)
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button { selectedDay = max(1, selectedDay - 1) } label: { kidNavCircle("chevron.left") }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(CalendarData.dayNames[selectedDay] ?? ""), Sep \(selectedDay)")
                        .font(Typography.display(kid.of(18, 22), weight: .bold))
                        .foregroundStyle(KidTheme.ink)
                    if selectedDay == CalendarData.dataDay {
                        Text("TODAY")
                            .font(Typography.font(kid.of(10, 11.5), weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(KidTheme.greenDeep)
                    }
                }
                Spacer()
                Button { selectedDay = min(CalendarData.daysInDataMonth, selectedDay + 1) } label: { kidNavCircle("chevron.right") }
            }

            // "Just me / Whole family" — a plain two-way switch, not the
            // parent side's tap-to-dim avatar row. A kid isn't managing a
            // household of lanes; they're deciding between two things:
            // their own day, or everyone's.
            HStack(spacing: 0) {
                // Wrapped in withAnimation — an un-animated toggle here
                // instantly swaps the single-lane timeline for the
                // multi-lane family grid (lane header appearing, every
                // block re-laying out), which reads as a jarring jump cut
                // rather than a deliberate switch and makes the control
                // itself feel broken/hard to use even though the tap is
                // registering fine.
                segmentButton(title: "Just me", isOn: !showWholeFamily) { withAnimation(.easeInOut(duration: 0.22)) { showWholeFamily = false } }
                segmentButton(title: "Whole family", isOn: showWholeFamily) { withAnimation(.easeInOut(duration: 0.22)) { showWholeFamily = true } }
            }
            .padding(4)
            .background(KidTheme.muted)
            .clipShape(Capsule())
        }
        .padding(.horizontal, kid.of(16, 20))
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func segmentButton(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(kid.of(13, 15), weight: .bold))
                .foregroundStyle(isOn ? .white : KidTheme.inkSoft)
                .frame(maxWidth: .infinity)
                .frame(height: kid.of(36, 42))
                .background(isOn ? KidTheme.greenDeep : Color.clear)
                .contentShape(Capsule())
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func kidNavCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: kid.of(15, 17), weight: .bold))
            .foregroundStyle(KidTheme.ink)
            .frame(width: kid.of(34, 40), height: kid.of(34, 40))
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Lane header / ANYTIME (whole-family mode only)

    private var laneHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColW)
            ForEach(lanes) { p in
                VStack(spacing: 3) {
                    Circle().fill(p.color).frame(width: kid.of(32, 38), height: kid.of(32, 38))
                        .overlay(Text(String(p.name.prefix(1))).font(Typography.font(kid.of(13, 15), weight: .bold)).foregroundStyle(.white))
                    Text(p.id == TabletData.child.id ? "Me" : p.name)
                        .font(Typography.font(kid.of(9.5, 11), weight: .semibold))
                        .foregroundStyle(KidTheme.ink)
                }
                .frame(maxWidth: .infinity)
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
                .foregroundStyle(KidTheme.inkSoft)
                .frame(width: timeColW, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 2)
            ForEach(lanes) { p in
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

    private func anytimeChip(_ de: CalDayEvent) -> some View {
        let ev = de.event
        let p = CalendarData.person(ev.personId)
        return Button { selectedEvent = de } label: {
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

    // MARK: - Grid blocks

    private func familyBlock(_ de: CalDayEvent, trackWidth: CGFloat) -> some View {
        let ev = de.event
        let p = CalendarData.everyone
        let top = evTop(ev.start)
        let height = max(evTop(ev.end) - top, 28)
        return Button { selectedEvent = de } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill").font(.system(size: 9, weight: .bold))
                    Text(ev.title)
                        .font(Typography.font(11, weight: .heavy))
                        .lineLimit(1)
                }
                if height > 34 {
                    Text("\(ev.start) \u{2013} \(ev.end) \u{00b7} everyone")
                        .font(Typography.font(9.5, weight: .semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: max(trackWidth - 4, 24), height: height, alignment: .topLeading)
            .background(p.color)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.35)).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: p.color.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + 2, y: top + 1)
    }

    // Events only now — tasks never enter this pipeline (see `laidOut`
    // above), so there's nothing left to tell apart by shape; every block
    // here just happens, at a time. Matches ScreenCalendar's own
    // DayTimelineView.eventBlock, with the emoji/repeat glyph kept from
    // this screen's original kid-facing look.
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
        return Button { selectedEvent = item.dayEvent } label: {
            VStack(alignment: .leading, spacing: 2) {
                if item.height > 38 {
                    Text(ev.emoji).font(.system(size: 11))
                }
                HStack(spacing: 3) {
                    if ev.repeats != "none" {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    }
                    Text(ev.title)
                        .font(Typography.font(11, weight: .heavy))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.top, item.height > 40 ? 7 : 4)
                .frame(width: w, height: item.height, alignment: .topLeading)
                .background(p.color)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + laneLeft + subLeft + 3, y: item.top)
        .zIndex(1)
    }

    // MARK: - Deadline markers — a due moment has no duration, so it's a
    // full-lane-width rule (marks exactly when) with a pill flush against
    // its top edge, both positioned against the lane column itself, drawn
    // above every event and the family band. Matches ScreenCalendar's own
    // DayTimelineView.taskDueMarker/dueGroupTint/dueGroupPill.
    private static let dueMarkerHeight: CGFloat = 24
    private static let dueMarkerInset: CGFloat = 2

    private func taskDueMarker(_ group: TaskDueGroup, trackWidth: CGFloat) -> some View {
        Group {
            if let colIndex = lanes.firstIndex(where: { $0.id == group.personId }) {
                let laneWidth = trackWidth / CGFloat(max(lanes.count, 1))
                let laneLeft = laneWidth * CGFloat(colIndex)
                let pillWidth = max(laneWidth - Self.dueMarkerInset * 2, 32)
                let dueY = evTop(group.start)

                Rectangle()
                    .fill(dueGroupTint(group))
                    .frame(width: pillWidth, height: 2)
                    .offset(x: timeColW + laneLeft + Self.dueMarkerInset, y: dueY)
                    .zIndex(50)

                Button {
                    // A group of exactly one is really just that one task —
                    // go straight to its detail. The kid side is read-only
                    // (no approve/redo), so a real group with more than one
                    // task due at once just opens the first — there's
                    // nothing to pick between beyond seeing what's due.
                    selectedEvent = group.tasks[0]
                } label: {
                    dueGroupPill(group, width: pillWidth)
                }
                .buttonStyle(.plain)
                .offset(x: timeColW + laneLeft + Self.dueMarkerInset, y: dueY - Self.dueMarkerHeight)
                .zIndex(51)
            }
        }
    }

    // Blue if waiting on a parent to check it, green (struck through) once
    // approved, otherwise the kid's own lane colour — same priority the
    // pill border uses, and the same blue/green split ScreenTabletHome's
    // task cards use for "submitted" vs "done."
    private func dueGroupTint(_ group: TaskDueGroup) -> Color {
        if group.tasks.contains(where: { $0.event.taskState == .submitted }) {
            return Color(hex: "2563EB")
        }
        if group.tasks.allSatisfy({ $0.event.taskState == .done }) {
            return KidTheme.greenDeep
        }
        return CalendarData.person(group.personId).color
    }

    private func dueGroupPill(_ group: TaskDueGroup, width: CGFloat) -> some View {
        let tint = dueGroupTint(group)
        let allDone = group.tasks.allSatisfy { $0.event.taskState == .done }

        return HStack(spacing: 4) {
            statusIcon(group.tasks[0].event)
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
        .background(allDone ? tint.opacity(0.12) : Color.white)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(tint, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// A quick look, not an editor — a kid can see what something is and when,
// nothing more. No status change, no delete; that stays a parent action
// wherever it already lives (ScreenProfile for tasks, ScreenCalendar for
// events).
private struct KidEventDetailSheet: View {
    var dayEvent: CalDayEvent

    private var event: CalEvent { dayEvent.event }
    private var person: FamilyPerson { CalendarData.person(event.personId) }

    private var whenLabel: String {
        if event.isAnytime { return "Anytime today" }
        if event.category == "Task" { return "Due \(event.start)" }
        return "\(event.start) \u{2013} \(event.end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(person.color).frame(width: 40, height: 40)
                    .overlay(Text(String(person.name.prefix(1))).font(Typography.font(15, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.emoji) \(event.title)")
                        .font(Typography.display(19, weight: .bold))
                        .foregroundStyle(KidTheme.ink)
                    Text(person.id == TabletData.child.id ? "Me" : person.name)
                        .font(Typography.font(12, weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                Spacer(minLength: 0)
            }

            Divider().background(KidTheme.line)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(KidTheme.inkSoft).frame(width: 20)
                    Text(whenLabel).font(Typography.font(14, weight: .medium)).foregroundStyle(KidTheme.ink)
                }
                if !event.location.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle").font(.system(size: 14)).foregroundStyle(KidTheme.inkSoft).frame(width: 20)
                        Text(event.location).font(Typography.font(14, weight: .medium)).foregroundStyle(KidTheme.ink)
                    }
                }
                if !event.note.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "note.text").font(.system(size: 14)).foregroundStyle(KidTheme.inkSoft).frame(width: 20)
                        Text(event.note).font(Typography.font(14, weight: .regular)).foregroundStyle(KidTheme.ink)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .background(KidTheme.background)
    }
}
