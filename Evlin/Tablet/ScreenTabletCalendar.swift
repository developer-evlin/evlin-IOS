import SwiftUI

// The kid's calendar: the parent's calendar view (DayTimelineView in
// ScreenCalendar.swift) in kid colours, showing only this kid. Events and
// tasks are the parent's and read-only here. The kid can plan something for
// a day with "+": it waits, pale and dashed, until a grown-up approves it
// (it then shows like any event) or says "Not this one". While a plan waits
// the kid can edit or delete it; a declined one stays until they tap
// "Okay, got it".
struct ScreenTabletCalendar: View {
    @Environment(SessionManager.self) private var session
    @State private var selectedDay = CalendarData.dataDay
    @State private var selectedEvent: CalDayEvent?
    @State private var tasksSheet: TasksSheetTarget?
    @State private var planForm: PlanFormTarget?
    @State private var savedTick = 0
    // The displayed month, read from the phone's database (TaskStore), so a
    // plan saved here or a parent's answer is on screen the moment it lands.
    private var eventsByDay: [Int: [CalEvent]] { TaskStore.shared.calendar }

    // A single lane is reading-shaped content, so on iPad it's centered in
    // a column rather than stretched across the full width.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }
    private var calendarMaxWidth: CGFloat? { kid.isRegular ? 640 : nil }

    // session.activeChildId is the real synced child (set by
    // AppSync.syncKidDevice), same source ScreenTabletHome uses.
    private var selfChildId: String { session.activeChildId ?? FamilyStore.children.first?.id ?? "" }
    private var selfPerson: FamilyPerson { CalendarData.person(selfChildId) }

    var body: some View {
        DayTimelineView(
            selectedDay: $selectedDay,
            visiblePeople: [selfPerson],
            focusedChildId: .constant(nil),
            isActive: true,
            eventsByDay: eventsByDay,
            onSelect: { selectedEvent = $0 },
            onShowTasks: { day, ids in tasksSheet = TasksSheetTarget(day: day, personIds: ids) },
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
            onAdd: { planForm = PlanFormTarget(day: selectedDay, editing: nil) },
            style: .kid
        )
        .kidContentColumn(calendarMaxWidth)
        .background(KidTheme.background)
        // Past midnight: a calendar that was on today moves to the new today.
        .onChange(of: DayClock.shared.today) { old, new in
            selectedDay = CalendarData.followingToday(selectedDay, from: old, to: new)
        }
        .sheet(item: $tasksSheet) { target in
            Group {
            DayTasksSheet(
                people: [selfPerson],
                tasks: CalendarData.expandedEvents(for: target.day, in: eventsByDay)
                    .filter { $0.event.category == "Task" && $0.event.personId == selfChildId },
                readOnly: true,
                onClose: { tasksSheet = nil }
            )
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedEvent) { de in
            Group {
            let ownPlan = de.event.isKidPlan && de.event.planStatus != .approved
            KidEventDetailSheet(
                dayEvent: de,
                onEdit: de.event.planStatus == .proposed && de.event.isKidPlan ? {
                    selectedEvent = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        planForm = PlanFormTarget(day: de.originDay, editing: de.event)
                    }
                } : nil,
                onRemove: ownPlan ? {
                    removePlan(de.event, originDay: de.originDay)
                    selectedEvent = nil
                } : nil
            )
            .presentationDetents(ownPlan ? [.medium] : [.height(320)])
            .presentationDragIndicator(.visible)
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $planForm) { target in
            Group {
            KidPlanForm(target: target, onSave: { title, start, end, location, note in
                savePlan(target, title: title, start: start, end: end, location: location, note: note)
                savedTick += 1
                planForm = nil
            }, onCancel: { planForm = nil })
        }
            .presentationDragIndicator(.visible)
        }
        // A success tap when a plan is sent, as for the parent's adds.
        .sensoryFeedback(.success, trigger: savedTick)
    }

    // Saved to the phone's database, so it's on screen at once, and sent by
    // the outbox. A refused save is reported, and the sync after it puts
    // the calendar back as the server has it.
    private func savePlan(_ target: PlanFormTarget, title: String, start: Date, end: Date, location: String, note: String) {
        var plan: CalEvent
        if let old = target.editing {
            guard let remoteId = old.remoteId else { return }
            plan = old
            plan.title = title
            plan.start = ChildRule.fmtClock(start)
            plan.end = ChildRule.fmtClock(end)
            plan.location = location
            plan.note = note
            LocalStore.shared.mirrorEventSaved(CalendarSync.apiEvent(plan, id: remoteId, start: start, end: end))
            Outbox.send(APIClient.Write.updatePlan(eventId: remoteId, title: title, start: start, end: end, note: note, location: location),
                        childId: selfChildId, label: "Your plan")
        } else {
            let id = APIClient.Write.newId()
            plan = CalEvent(personId: selfChildId, title: title, emoji: emojiForCalendarCategory("Activity"),
                            start: ChildRule.fmtClock(start), end: ChildRule.fmtClock(end),
                            category: "Activity", location: location, note: note, repeats: "none")
            plan.isKidPlan = true
            plan.planStatus = .proposed
            LocalStore.shared.mirrorEventSaved(CalendarSync.apiEvent(plan, id: id, start: start, end: end))
            Outbox.send(APIClient.Write.createPlan(id: id, title: title, start: start, end: end, note: note, location: location),
                        childId: selfChildId, label: "Your plan")
        }
    }

    // Withdraws a waiting plan, or clears a declined one ("Okay, got it").
    private func removePlan(_ ev: CalEvent, originDay: Int) {
        guard let remoteId = ev.remoteId else { return }
        withAnimation(.snappy(duration: 0.3)) { LocalStore.shared.mirrorEventDeleted(id: remoteId) }
        Outbox.send(APIClient.Write.deletePlan(eventId: remoteId), childId: selfChildId, label: "Removing your plan")
    }
}

// The plan form: a new plan on `day`, or the kid's own waiting plan.
struct PlanFormTarget: Identifiable {
    var day: Int
    var editing: CalEvent?
    var id: String { editing?.id.uuidString ?? "new-\(day)" }
}

// What a kid fills in to plan something: what, when (on the day open in
// the calendar), where, and a note. Sent to a grown-up to approve.
private struct KidPlanForm: View {
    var target: PlanFormTarget
    var onSave: (_ title: String, _ start: Date, _ end: Date, _ location: String, _ note: String) -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var location: String
    @State private var note: String

    init(target: PlanFormTarget, onSave: @escaping (String, Date, Date, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        let ev = target.editing
        let startMin = ev.map { CalendarData.minutesSinceMidnight($0.start) } ?? Self.nextHalfHour(on: target.day)
        let endMin = ev.map { CalendarData.minutesSinceMidnight($0.end) } ?? min(startMin + 60, 23 * 60 + 59)
        _title = State(initialValue: ev?.title ?? "")
        _startTime = State(initialValue: CalendarData.date(day: target.day, minutes: startMin))
        _endTime = State(initialValue: CalendarData.date(day: target.day, minutes: endMin))
        _location = State(initialValue: ev?.location ?? "")
        _note = State(initialValue: ev?.note ?? "")
    }

    // The next half-hour today, or 4 PM on another day.
    private static func nextHalfHour(on day: Int) -> Int {
        let isToday = day == CalendarData.dataDay && CalendarData.isDisplayingCurrentMonth
        guard isToday else { return 16 * 60 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return min(((m / 30) + 1) * 30, 23 * 60)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    // The picked times on the plan's day; an end before the start moves to
    // an hour after it.
    private func onDay(_ time: Date) -> Date {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return CalendarData.date(day: target.day, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    var body: some View {
        FormShell(
            title: target.editing == nil ? "Plan something" : "Edit my plan",
            onCancel: onCancel,
            onSave: {
                let start = onDay(startTime)
                var end = onDay(endTime)
                if end <= start { end = start.addingTimeInterval(3600) }
                onSave(title.trimmingCharacters(in: .whitespaces), start, end,
                       location.trimmingCharacters(in: .whitespaces), note.trimmingCharacters(in: .whitespaces))
            },
            canSave: canSave,
            saveLabel: target.editing == nil ? "Send to a grown-up" : "Save changes"
        ) {
            FormField(label: "What") {
                FormTextField(placeholder: "e.g. Build a LEGO castle", text: $title, scrollToTopOnFocus: true)
            }
            FormField(label: "When") {
                HStack(spacing: 8) {
                    FormTimeField(date: $startTime)
                    Text("\u{2013}").foregroundStyle(EColor.onSurfaceVariant)
                    FormTimeField(date: $endTime)
                }
            }
            FormField(label: "Where") {
                FormTextField(placeholder: "Optional", text: $location)
            }
            FormField(label: "Notes") {
                TextField("Anything a grown-up should know…", text: $note, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .lineLimit(3...5)
                    .padding(14)
                    .background(FormGreen.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

// A quick look at an event or task. For the kid's own plan it also says
// where it stands, and while it waits offers Edit and Delete; once a grown-up
// says "Not this one" it shows their note and "Okay, got it", which clears it.
private struct KidEventDetailSheet: View {
    @Environment(SessionManager.self) private var session
    var dayEvent: CalDayEvent
    var onEdit: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @State private var confirmDelete = false

    private var event: CalEvent { dayEvent.event }
    private var person: FamilyPerson { CalendarData.person(event.personId) }
    private var selfChildId: String { session.activeChildId ?? FamilyStore.children.first?.id ?? "" }

    private var whenLabel: String {
        if event.isAnytime {
            let today = dayEvent.day == CalendarData.dataDay && CalendarData.isDisplayingCurrentMonth
            return today ? "All day today" : "All day"
        }
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
                    Text(person.id == selfChildId ? "Me" : person.name)
                        .font(Typography.font(12, weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)
                }
                Spacer(minLength: 0)
            }

            if event.isKidPlan && event.planStatus != .approved {
                planStatus
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

            planActions
        }
        .padding(24)
        .background(KidTheme.background)
        .alert("Delete this plan?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onRemove?() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var planStatus: some View {
        if event.planStatus == .proposed {
            Label("Waiting for a grown-up", systemImage: "hourglass")
                .font(Typography.font(13, weight: .bold))
                .foregroundStyle(person.color)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(person.color.opacity(0.12), in: Capsule())
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Not this one", systemImage: "xmark.circle")
                    .font(Typography.font(13, weight: .bold))
                    .foregroundStyle(KidTheme.inkSoft)
                if let note = event.reviewNote, !note.isEmpty {
                    Text("\u{201C}\(note)\u{201D}")
                        .font(Typography.font(14, weight: .medium))
                        .foregroundStyle(KidTheme.ink)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KidTheme.muted, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private var planActions: some View {
        if event.isKidPlan && event.planStatus == .declined, let onRemove {
            Button(action: onRemove) {
                Text("Okay, got it")
                    .font(Typography.font(17, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(KidTheme.greenDeep, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        } else if event.isKidPlan && event.planStatus == .proposed {
            HStack(spacing: 12) {
                if onRemove != nil {
                    Button { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                            .font(Typography.font(16, weight: .heavy))
                            .foregroundStyle(EColor.danger)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.line, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(Typography.font(16, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(KidTheme.greenDeep, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
