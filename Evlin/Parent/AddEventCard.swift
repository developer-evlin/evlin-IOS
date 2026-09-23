import SwiftUI

/// The calendar counterpart to AddTaskCard: the model works out the details,
/// the parent confirms. Same never-writes rule — nothing reaches the
/// calendar until Add is tapped.
struct AddEventCard: View {
    var draft: EventDraft
    var onCreate: (_ draft: EventDraft) -> Void

    @State private var title: String
    @State private var day: Date
    @State private var start: Date
    @State private var end: Date
    @State private var recurrence: String
    @State private var isFamily: Bool
    @State private var note: String
    @State private var submitted = false

    init(draft: EventDraft, onCreate: @escaping (_ draft: EventDraft) -> Void) {
        self.draft = draft
        self.onCreate = onCreate
        _title = State(initialValue: draft.title)
        _day = State(initialValue: draft.startDate)
        _start = State(initialValue: draft.startsAt)
        _end = State(initialValue: draft.endsAt)
        _recurrence = State(initialValue: draft.recurrence)
        _isFamily = State(initialValue: draft.isFamily)
        _note = State(initialValue: draft.note)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var canCreate: Bool { !trimmedTitle.isEmpty && !submitted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(EColor.primary)
                Text("Add to calendar").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
                Spacer()
                if submitted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.greenDeep)
                }
            }

            TextField("Event name", text: $title)
                .font(Typography.font(17, weight: .semibold))
                .textFieldStyle(.plain)

            Divider()

            row(icon: "calendar", label: "Date") {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact)
            }
            row(icon: "clock", label: "Starts") {
                DatePicker("", selection: $start, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.compact)
            }
            row(icon: "clock.badge.checkmark", label: "Ends") {
                DatePicker("", selection: $end, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.compact)
            }

            row(icon: "repeat", label: "Repeats") {
                Menu {
                    Button("Doesn't repeat") { recurrence = "none" }
                    Button("Every day") { recurrence = "sun,mon,tue,wed,thu,fri,sat" }
                    Button("Weekdays") { recurrence = "mon,tue,wed,thu,fri" }
                    Button("Weekends") { recurrence = "sat,sun" }
                } label: {
                    HStack(spacing: 4) {
                        Text(recurrence == "none" ? "Doesn't repeat" : repeatDisplayLabel(recurrence))
                            .font(Typography.font(14, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(EColor.primary)
                }
            }

            Toggle(isOn: $isFamily) {
                Label("Whole family", systemImage: "person.2")
                    .font(Typography.font(14))
                    .foregroundStyle(EColor.onSurface)
            }
            .frame(minHeight: 44)

            Button {
                submitted = true
                onCreate(currentDraft)
            } label: {
                Text("Add to calendar")
                    .font(Typography.font(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canCreate ? Brand.greenDeep : EColor.outlineVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(16)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EColor.outlineVariant))
        .disabled(submitted)
    }

    @ViewBuilder
    private func row<Content: View>(icon: String, label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(EColor.onSurfaceVariant)
                .frame(width: 20)
            Text(label).font(Typography.font(14)).foregroundStyle(EColor.onSurface)
            Spacer()
            content()
        }
        .frame(minHeight: 44)
    }

    private var currentDraft: EventDraft {
        var out = draft
        out.title = trimmedTitle
        out.startDate = day
        let s = Calendar.current.dateComponents([.hour, .minute], from: start)
        let e = Calendar.current.dateComponents([.hour, .minute], from: end)
        out.startMinutes = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        out.endMinutes = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        // An end before the start would save an event the grid can't draw.
        if out.endMinutes <= out.startMinutes { out.endMinutes = out.startMinutes + 60 }
        out.recurrence = recurrence
        out.isFamily = isFamily
        out.note = note
        return out
    }
}
