import SwiftUI

/// Blocking apps from chat: which apps, and for a while, until a task is
/// approved, until lifted, or on a weekly schedule. Opened from the "Block an
/// app" tile; nothing is blocked until Confirm. Apps come from Evlin's
/// catalog, and one not yet on the child's list is added when confirming.
struct AppBlockDraftCard: View {
    let childId: String
    let childName: String
    var onDone: (String) -> Void

    @State private var kind: BlockDraft.Kind
    @State private var selected: Set<String>
    @State private var knownNames: [String: String]
    @State private var durationMinutes: Int?
    @State private var untilTaskId: String?
    @State private var days: Set<String>
    @State private var start: Date
    @State private var end: Date
    @State private var showPicker = false
    @State private var query = ""
    @State private var onList: Set<String>?
    @State private var saving = false
    @State private var finished = false
    @State private var errorText: String?

    private let durations = [15, 30, 60, 120, 240]

    init(draft: BlockDraft, childId: String, childName: String, onDone: @escaping (String) -> Void) {
        self.childId = childId
        self.childName = childName
        self.onDone = onDone
        _kind = State(initialValue: draft.kind)
        _selected = State(initialValue: Set(draft.apps.map(\.id)))
        _knownNames = State(initialValue: Dictionary(draft.apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        _durationMinutes = State(initialValue: draft.durationMinutes)
        _untilTaskId = State(initialValue: draft.untilTaskId)
        _days = State(initialValue: draft.days)
        _start = State(initialValue: Self.date(minutes: draft.startMinutes ?? 19 * 60))
        _end = State(initialValue: Self.date(minutes: draft.endMinutes ?? 7 * 60))
    }

    // MARK: derived

    private var tasks: [ChildTask] { TaskStore.tasks(for: childId) }

    private func name(_ id: String) -> String {
        knownNames[id] ?? AppCatalog.shared.app(id: id)?.name ?? "App"
    }

    private var orderedSelection: [String] { selected.sorted { name($0) < name($1) } }

    /// Picked apps that aren't on the child's list yet — confirming adds
    /// them, and the card says so first.
    private var toAdd: [String] {
        guard let onList else { return [] }
        return orderedSelection.filter { !onList.contains($0) }
    }

    private var ready: Bool {
        guard !selected.isEmpty else { return false }
        switch kind {
        case .duration: return durationMinutes != nil
        case .untilTask: return untilTaskId != nil
        case .scheduled: return !days.isEmpty && minutes(of: start) != minutes(of: end)
        case .indefinite: return true
        }
    }

    // MARK: body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(EColor.danger)
                Text("Block apps").font(Typography.font(15, weight: .bold)).foregroundStyle(EColor.onSurface)
            }

            appsSection
            kindSection

            switch kind {
            case .duration: durationSection
            case .untilTask: taskSection
            case .scheduled: scheduleSection
            case .indefinite: EmptyView()
            }

            if !toAdd.isEmpty {
                Text("\(toAdd.map(name).joined(separator: ", ")) will be added to \(childName)'s apps.")
                    .font(Typography.font(12, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
            }
            if let errorText { note(errorText) }
            if !finished { confirmButton }
        }
        .padding(14)
        .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EColor.outlineVariant))
        .disabled(finished)
        .task {
            await AppCatalog.shared.load()
            onList = Set((try? await APIClient.shared.fetchChildApps(childId: childId))?.map(\.id) ?? [])
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowChips {
                ForEach(orderedSelection, id: \.self) { id in
                    HStack(spacing: 6) {
                        AppIconView(appName: name(id), size: 22)
                        Text(name(id)).font(Typography.font(13, weight: .semibold)).foregroundStyle(EColor.onSurface)
                        Button { selected.remove(id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(EColor.onSurfaceVariant)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(name(id))")
                    }
                    .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 5)
                    .background(EColor.surfaceContainerHigh)
                    .clipShape(Capsule())
                }
                Button { withAnimation(.easeInOut(duration: 0.15)) { showPicker.toggle() } } label: {
                    Label(selected.isEmpty ? "Choose apps" : "Add", systemImage: showPicker ? "chevron.up" : "plus")
                        .font(Typography.font(13, weight: .semibold))
                        .foregroundStyle(EColor.danger)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(EColor.danger.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
            if showPicker {
                BlockTargetPicker(query: $query, selectedApps: $selected)
            }
        }
    }

    private var kindSection: some View {
        FlowChips {
            ForEach(BlockDraft.Kind.allCases, id: \.self) { option in
                chip(option.label, selected: kind == option) { kind = option }
            }
        }
    }

    private var durationSection: some View {
        FlowChips {
            ForEach(durations, id: \.self) { minutes in
                chip(formatMinutes(minutes), selected: durationMinutes == minutes) { durationMinutes = minutes }
            }
        }
    }

    @ViewBuilder private var taskSection: some View {
        if tasks.isEmpty {
            note("\(childName) has no tasks yet to tie this to.")
        } else {
            FlowChips {
                ForEach(tasks) { task in
                    chip(task.title, selected: untilTaskId == task.id) { untilTaskId = task.id }
                }
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(weekDayCodes.enumerated()), id: \.offset) { i, code in
                    let on = days.contains(code)
                    Button {
                        if on { days.remove(code) } else { days.insert(code) }
                    } label: {
                        Text(weekDayInitials[i])
                            .font(Typography.font(12.5, weight: .bold))
                            .foregroundStyle(on ? .white : EColor.onSurface)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(on ? EColor.danger : EColor.surfaceContainerHigh))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(code)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                Text("to").font(Typography.font(13)).foregroundStyle(EColor.onSurfaceVariant)
                DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
            }
            if minutes(of: end) < minutes(of: start) {
                Text("Runs overnight, into the next morning.")
                    .font(Typography.font(12, weight: .medium))
                    .foregroundStyle(EColor.onSurfaceVariant)
            }
        }
    }

    private var confirmButton: some View {
        Button { Task { await confirm() } } label: {
            Text(saving ? "Blocking…" : (selected.count > 1 ? "Block \(selected.count) apps" : "Block"))
                .font(Typography.font(13.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(ready && !saving ? EColor.danger : EColor.outlineVariant)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!ready || saving)
    }

    // MARK: pieces

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(12, weight: .semibold))
                .foregroundStyle(selected ? .white : EColor.onSurface)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? EColor.danger : EColor.surfaceContainerHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.font(12.5, weight: .medium))
            .foregroundStyle(Color(hex: "C2410C"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    // MARK: save

    private func confirm() async {
        guard ready, !saving else { return }
        saving = true
        errorText = nil
        defer { saving = false }
        let ids = orderedSelection
        do {
            _ = try await APIClient.shared.createAppBlocks(
                childId: childId, appIds: ids, blockType: kind.rawValue,
                durationMinutes: kind == .duration ? durationMinutes : nil,
                untilTaskId: kind == .untilTask ? untilTaskId : nil,
                scheduleDays: kind == .scheduled ? weekDayCodes.filter { days.contains($0) }.joined(separator: ",") : nil,
                scheduleStart: kind == .scheduled ? BlockDraft.hhmm(minutes(of: start)) : nil,
                scheduleEnd: kind == .scheduled ? BlockDraft.hhmm(minutes(of: end)) : nil,
                addToList: !toAdd.isEmpty
            )
            finished = true
            onDone("Blocked \(Self.list(ids.map(name))) \(summary).")
            await AppSync.shared.syncBackendData()
        } catch {
            errorText = "That didn't save. \(error.apiUserMessage)"
        }
    }

    private var summary: String {
        switch kind {
        case .duration: return "for \(formatMinutes(durationMinutes ?? 0))"
        case .untilTask:
            let title = tasks.first { $0.id == untilTaskId }?.title ?? "the task"
            return "until \(title) is approved"
        case .indefinite: return "until you lift it"
        case .scheduled:
            let label = repeatDisplayLabel(weekDayCodes.filter { days.contains($0) }.joined(separator: ","))
            return "\(label.isEmpty ? "on those days" : label), \(BlockDraft.hhmm(minutes(of: start)))–\(BlockDraft.hhmm(minutes(of: end)))"
        }
    }

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}
