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
    var span: Int
    var numCols: Int
}

// Overlapping events split width between themselves and expand rightward
// into columns that stay free for their whole span, Google-Calendar style.
// Column assignment is a FIXED per-person lane (Family, then each kid in
// CalendarData.people order) rather than first-fit bin-packing — so
// whenever two people's events overlap, each person's block always lands
// in the same relative left-to-right slot (and same color) instead of
// shifting around based on whatever happened to fit first that day.
private func layoutDayEvents(_ events: [CalDayEvent]) -> [LaidOutEvent] {
    struct Item { var dayEvent: CalDayEvent; var start: CGFloat; var end: CGFloat }
    var items = events.map { de -> Item in
        let start = evTop(de.event.start)
        let end = max(evTop(de.event.end), start + 1)
        return Item(dayEvent: de, start: start, end: end)
    }
    items.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }

    var groups: [[Item]] = []
    var group: [Item] = []
    var groupEnd: CGFloat = -.greatestFiniteMagnitude
    for item in items {
        if group.isEmpty || item.start < groupEnd {
            group.append(item)
            groupEnd = max(groupEnd, item.end)
        } else {
            groups.append(group)
            group = [item]
            groupEnd = item.end
        }
    }
    if !group.isEmpty { groups.append(group) }

    var result: [LaidOutEvent] = []
    for g in groups {
        // Only the people actually present in this overlap group get a
        // lane, so a single-person group still renders full-width — the
        // fixed ordering only matters once there's something to stay
        // consistent relative to.
        let presentPersonIds = CalendarData.people.map(\.id).filter { pid in g.contains { $0.dayEvent.event.personId == pid } }
        let numCols = presentPersonIds.count
        var columns: [[Item]] = Array(repeating: [], count: numCols)
        for item in g {
            guard let ci = presentPersonIds.firstIndex(of: item.dayEvent.event.personId) else { continue }
            columns[ci].append(item)
        }
        for (ci, col) in columns.enumerated() {
            for item in col {
                var span = 1
                var c = ci + 1
                while c < numCols {
                    let blocked = columns[c].contains { !($0.end <= item.start || $0.start >= item.end) }
                    if blocked { break }
                    span += 1
                    c += 1
                }
                result.append(LaidOutEvent(id: item.dayEvent.id, dayEvent: item.dayEvent, top: item.start, height: item.end - item.start, col: ci, span: span, numCols: numCols))
            }
        }
    }
    return result
}

struct ScreenCalendar: View {
    @State private var selectedDay = CalendarData.dataDay
    @State private var showDatePicker = false
    @State private var focusPerson: String?
    @State private var eventsByDay: [Int: [CalEvent]] = CalendarData.eventsByDay
    @State private var activeDayEvent: CalDayEvent?
    @State private var showAddEvent = false

    private func expandedEvents(for day: Int) -> [CalDayEvent] {
        CalendarData.expandedEvents(for: day, in: eventsByDay)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dateHeader
                DayTimelineView(selectedDay: selectedDay, focusPerson: $focusPerson, events: expandedEvents(for: selectedDay), onSelect: { activeDayEvent = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(EColor.surface)
            // safeAreaInset reserves real layout space for the FAB, so the
            // last row of whichever view is showing can never end up
            // rendered underneath it.
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
                if let i = eventsByDay[de.originDay]?.firstIndex(where: { $0.id == de.event.id }) {
                    eventsByDay[de.originDay]?[i] = updated
                }
                activeDayEvent = nil
            }, onDelete: {
                eventsByDay[de.originDay]?.removeAll { $0.id == de.event.id }
                activeDayEvent = nil
            }, onClose: { activeDayEvent = nil })
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
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.visible)
        }
    }

    private var dateHeader: some View {
        HStack {
            Button { selectedDay = max(1, selectedDay - 1) } label: { navCircle("chevron.left") }
            Spacer()
            Button { showDatePicker = true } label: {
                VStack(spacing: 2) {
                    Text("\(CalendarData.dayNames[selectedDay] ?? ""), Sep \(selectedDay)")
                        .font(Typography.font(17, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                    Text("TAP TO CHANGE DATE")
                        .font(Typography.font(10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EColor.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { selectedDay = min(CalendarData.daysInDataMonth, selectedDay + 1) } label: { navCircle("chevron.right") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(EColor.surfaceContainerLowest)
        .overlay(Divider(), alignment: .bottom)
    }

    private func navCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(EColor.primary)
            .frame(width: 34, height: 34)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: EShadow.premium, radius: 6, y: 2)
    }
}

// MARK: - Day timeline

private struct DayTimelineView: View {
    var selectedDay: Int
    @Binding var focusPerson: String?
    var events: [CalDayEvent]
    var onSelect: (CalDayEvent) -> Void

    private var visiblePeople: [FamilyPerson] {
        if let focusPerson { return CalendarData.people.filter { $0.id == focusPerson } }
        return CalendarData.people
    }

    private var filteredEvents: [CalDayEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.event.personId == focusPerson }
    }

    private var hours: [Int] { Array(startHour...endHour) }

    var body: some View {
        Card(padded: false) {
            VStack(spacing: 0) {
                HStack {
                    Text(selectedDay == CalendarData.dataDay ? "Today's Events" : "Sep \(selectedDay)")
                        .font(Typography.font(16, weight: .heavy)).foregroundStyle(EColor.onSurface)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                HStack(spacing: 14) {
                    if focusPerson != nil {
                        Button { focusPerson = nil } label: {
                            Image(systemName: "person.3.fill")
                                .frame(width: 28, height: 28)
                                .background(EColor.primaryContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(EColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 0) {
                        ForEach(visiblePeople) { p in
                            Button {
                                focusPerson = (focusPerson == p.id) ? nil : p.id
                            } label: {
                                VStack(spacing: 4) {
                                    Circle().fill(p.color).frame(width: 36, height: 36)
                                        .overlay(Text(String(p.name.prefix(1))).font(Typography.font(14, weight: .bold)).foregroundStyle(.white))
                                    Text(p.name).font(Typography.font(10, weight: .semibold))
                                        .foregroundStyle(focusPerson == p.id ? p.color : EColor.onSurface)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                Divider()

                // Opens at the top of the day rather than auto-scrolling to
                // the first event — SwiftUI's ScrollViewReader.scrollTo
                // relies on a view's *layout* position, which offset()-based
                // absolute placement (used below for the timeline rows)
                // never updates, so any scrollTo target here always resolved
                // to the same spot. Not worth chasing further for what's a
                // cosmetic nicety; a plain top-opening scroll is standard
                // calendar behavior anyway.
                ScrollView {
                    GeometryReader { geo in
                        let trackWidth = geo.size.width - timeColW
                        let laidOut = layoutDayEvents(filteredEvents)
                        ZStack(alignment: .topLeading) {
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
                                .offset(y: timeToY(h) - 6)
                            }

                            ForEach(laidOut) { item in
                                eventBlock(item, trackWidth: trackWidth)
                            }
                        }
                    }
                    .frame(height: timeToY(endHour) + 24)
                }
            }
        }
        .padding(12)
    }

    private func eventBlock(_ item: LaidOutEvent, trackWidth: CGFloat) -> some View {
        let p = CalendarData.person(item.dayEvent.event.personId)
        let widthFrac = CGFloat(item.span) / CGFloat(item.numCols)
        let leftFrac = CGFloat(item.col) / CGFloat(item.numCols)
        let w = max(trackWidth * widthFrac - 6, 24)
        return Button { onSelect(item.dayEvent) } label: {
            VStack(alignment: .leading, spacing: 2) {
                if item.height > 38 {
                    Text(item.dayEvent.event.emoji).font(.system(size: 11))
                }
                HStack(spacing: 3) {
                    if item.dayEvent.event.repeats != "none" {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    }
                    Text(item.dayEvent.event.title)
                        .font(Typography.font(11, weight: .heavy))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.top, item.height > 40 ? 7 : 4)
            .frame(width: w, height: item.height, alignment: .topLeading)
            .background(p.color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .offset(x: timeColW + trackWidth * leftFrac + 3, y: item.top)
    }
}

// MARK: - Month picker sheet

// Ported from the native Reminders/Calendar "tap to change date" pattern:
// tapping the day header opens this bottom sheet with a plain Sunday-first
// month grid; picking a day selects it and dismisses the sheet.
private struct MonthPickerSheet: View {
    var selectedDay: Int
    var onPickDay: (Int) -> Void

    private var cells: [Int?] { CalendarData.monthGrid(year: CalendarData.dataYear, month: CalendarData.dataMonth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CalendarData.monthFull[CalendarData.dataMonth - 1])
                .font(Typography.font(24, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
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

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(EColor.surface)
    }

    @ViewBuilder
    private func dayCell(_ d: Int?) -> some View {
        let isToday = d == CalendarData.dataDay
        let isSel = d == selectedDay && !isToday

        Button {
            if let d { onPickDay(d) }
        } label: {
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
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(d == nil)
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

    private let categories = ["Activity", "Lesson", "Sport", "Family", "Routine", "Study", "Chore"]

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
    }

    private var person: FamilyPerson { CalendarData.person(dayEvent.event.personId) }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    private var dateLabel: String {
        let name = CalendarData.dayNames[dayEvent.day] ?? ""
        let full = CalendarData.fullDayNames[name] ?? name
        return "\(full), September \(dayEvent.day)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                if editing { editContent } else { viewContent }
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
        }
        .background(EColor.surface)
        .alert("Delete \"\(dayEvent.event.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if editing { draft = dayEvent.event; editing = false } else { onClose() }
            } label: {
                Image(systemName: editing ? "chevron.left" : "xmark")
                    .foregroundStyle(EColor.onSurface)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            Text(editing ? "Edit event" : "")
                .font(Typography.font(13, weight: .bold))
                .foregroundStyle(EColor.onSurfaceVariant)
            Spacer()
            if editing {
                Button {
                    onSave(draft)
                } label: {
                    Text("Save")
                        .font(Typography.font(14, weight: .heavy))
                        .foregroundStyle(canSave ? .white : EColor.onSurfaceVariant)
                        .padding(.horizontal, 20).frame(height: 36)
                        .background(canSave ? EColor.primary : EColor.surfaceContainerHigh)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            } else {
                Button { editing = true } label: { Image(systemName: "pencil").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40) }
                    .buttonStyle(.plain)
                Button { showDeleteConfirm = true } label: { Image(systemName: "trash").foregroundStyle(EColor.onSurface).frame(width: 40, height: 40) }
                    .buttonStyle(.plain)
            }
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

    private var editContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormField(label: "Title") { FormTextField(placeholder: "Event title", text: $draft.title) }
            FormField(label: "Time") {
                HStack(spacing: 8) {
                    FormTextField(placeholder: "Start", text: $draft.start)
                    Text("\u{2013}").foregroundStyle(EColor.onSurfaceVariant)
                    FormTextField(placeholder: "End", text: $draft.end)
                }
            }
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
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
    }
}

// MARK: - Add event

// Ported from Evlin-iOS's AddCalendarForm (Views/Profile/AddBottomSheet.swift):
// Title, a free-text Start-End time pair, a category pill row (each with its
// own emoji, via `emojiForCalendarCategory`), and a Repeat pill row - same
// field set and FormShell chrome as AddTaskSheet, so "add event" feels like
// the same family of sheet as "add task."
private struct AddCalendarSheet: View {
    var onCreate: (CalEvent) -> Void
    var onCancel: () -> Void

    @State private var personId = CalendarData.people[0].id
    @State private var title = ""
    @State private var start = ""
    @State private var end = ""
    // Fixed rather than parent-picked — see removed "Category" FormField
    // below. Still feeds CalEvent.category/emoji since other screens (the
    // day-view Pill, etc.) read those.
    private let category = "Activity"
    @State private var repeatDays: Set<String> = []

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !start.trimmingCharacters(in: .whitespaces).isEmpty
            && !end.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        FormShell(title: "Add to Calendar", onCancel: onCancel, onSave: {
            let repeatCodes = weekDayCodes.filter { repeatDays.contains($0) }
            onCreate(CalEvent(
                personId: personId, title: title, emoji: emojiForCalendarCategory(category),
                start: start, end: end, category: category,
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
                    FormTextField(placeholder: "Start, e.g. 9:00 AM", text: $start)
                    Text("-").font(Typography.font(15, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
                    FormTextField(placeholder: "End, e.g. 10:00 AM", text: $end)
                }
            }
            RepeatPicker(selectedDays: $repeatDays)
        }
    }
}
