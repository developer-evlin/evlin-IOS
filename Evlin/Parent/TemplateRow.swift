import SwiftUI

/// The look every template list shares (task ideas in New task, the chore
/// picker, goal ideas): white, the icon in its colour on a pale wash of it,
/// the name in dark ink, one line under it in slate, and a + that turns
/// into a navy tick when picked. The colour is only on the icon, so the
/// list stays calm but each idea is easy to tell apart.
struct TemplateRow: View {
    var symbol: String
    var title: String
    var detail: String?
    var tint: Color? = nil
    var picked: Bool = false
    /// The trailing mark: false hides it (rows that fill a form rather
    /// than toggle a pick).
    var showsMark: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? Neutral.navy)
                .frame(width: 40, height: 40)
                .background((tint ?? Neutral.navy).opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(Neutral.ink)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Typography.font(13.5, weight: .regular))
                        .foregroundStyle(Neutral.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsMark {
                ZStack {
                    Circle().strokeBorder(picked ? .clear : TemplateStyle.ring, lineWidth: 1.5)
                    if picked { Circle().fill(Neutral.navy) }
                    Image(systemName: picked ? "checkmark" : "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(picked ? .white : Neutral.navy)
                }
                .frame(width: 28, height: 28)
                .animation(.snappy(duration: 0.2), value: picked)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A choice on the black cover (New task's ideas, the chore picker): a
/// full-width card in the idea's own colours, glowing a little, with a
/// white icon, the name large, why it helps, and a tag. Cards rise in one
/// after another. `picked` nil: tapping takes it at once (a →); true or
/// false: tapping adds or removes it (+ or ✓).
struct ChoiceCard: View {
    var symbol: String
    var title: String
    var why: String
    var tag: String?
    var colors: [Color]
    var picked: Bool? = nil
    var index: Int = 0
    var onTap: () -> Void

    @State private var shown = false

    var body: some View {
        let on = picked == true
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer()
                    Image(systemName: picked == nil ? "arrow.right" : on ? "checkmark" : "plus")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(on ? colors[0] : .white)
                        .frame(width: 34, height: 34)
                        .background(on ? Color.white : Color.white.opacity(0.22), in: Circle())
                        .animation(.snappy(duration: 0.2), value: on)
                }
                Text(title)
                    .font(Typography.font(19, weight: .heavy))
                    .padding(.top, 8)
                if !why.isEmpty {
                    Text(why)
                        .font(Typography.font(13.5, weight: .medium))
                        .opacity(0.9)
                        .lineLimit(1)
                }
                if let tag {
                    Text(tag)
                        .font(Typography.font(12.5, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.18), in: Capsule())
                        .padding(.top, 6)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(on ? 0.9 : 0), lineWidth: 2.5))
            .shadow(color: colors[0].opacity(0.45), radius: 18, y: 6)
        }
        .buttonStyle(CardPressStyle())
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 22)
        .scaleEffect(shown ? 1 : 0.96)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(Double(index) * 0.08)) { shown = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Shuffle, on black.
func darkShuffleButton(_ turns: Int, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 7) {
            Image(systemName: "shuffle")
                .font(.system(size: 13, weight: .bold))
                .rotationEffect(.degrees(Double(turns) * 180))
            Text("Shuffle")
        }
        .font(Typography.font(14, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.white.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Shuffle, show more ideas")
}

enum TemplateStyle {
    static let tile = Neutral.tile
    static let ring = Neutral.border

    /// The hairline above every row but the first.
    static func hairline(_ shown: Bool) -> some View {
        Rectangle().fill(Neutral.line).frame(height: 1).padding(.leading, 54).opacity(shown ? 1 : 0)
    }
}

/// The round kind buttons across the top of New task and New goal: an
/// icon in a plain ring, the picked one filled green. No labels, as in Apple's
/// own pickers; the picked kind's name heads the list under them.
struct PickKindButton: View {
    var symbol: String
    var name: String
    var on: Bool
    /// A drawn picture (`HabitArt`) in place of the symbol: picked, it sits
    /// on pale green in a green ring, since a green fill would hide it.
    var art: String? = nil
    var action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            Group {
                if let art, HabitArt.has(art) {
                    HabitArt(title: art)
                        .frame(width: 30, height: 30)
                        .frame(width: 46, height: 46)
                        .background(on ? FormGreen.accentBg : .clear, in: Circle())
                        .overlay(Circle().strokeBorder(on ? FormGreen.accent : Neutral.border, lineWidth: on ? 2.5 : 1.5))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? .white : Neutral.ink)
                        .frame(width: 46, height: 46)
                        .background(on ? FormGreen.accent : .clear, in: Circle())
                        .overlay(Circle().strokeBorder(on ? .clear : Neutral.border, lineWidth: 1.5))
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A kind's ideas as one rounded group, Apple's grouped list: the kind's
/// name over rows of an icon in a plain ring, the name and a chevron.
struct PickGroup<Item: Identifiable>: View {
    var heading: String
    var items: [Item]
    var symbol: (Item) -> String
    var title: (Item) -> String
    var onPick: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading.uppercased())
                .font(Typography.font(12.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Neutral.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Button { onPick(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Neutral.line).frame(height: 1).padding(.leading, 58)
                                .opacity(i > 0 ? 1 : 0)
                        }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            PickIcon(title: title(item), symbol: symbol(item))
            Text(title(item))
                .font(Typography.font(16, weight: .semibold))
                .foregroundStyle(Neutral.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Neutral.secondary)
        }
        .padding(.horizontal, 2)
        .frame(height: 62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// New task's two tabs. The one a parent last chose is what the sheet opens on
/// next time, so it settles into how they work: typing or picking. The very
/// first time it's the Library (2026-11-10, the user's call: a new parent on
/// Today sees the chores to pick from first).
enum NewTaskTab: String {
    case new, library

    static let key = "evlin.newTaskTab"
    static var remembered: NewTaskTab {
        UserDefaults.standard.string(forKey: key).flatMap(NewTaskTab.init) ?? .library
    }
}

/// New task | Library, over the sheet.
struct NewTaskTabs: View {
    var tab: NewTaskTab
    var onSelect: (NewTaskTab) -> Void

    @Namespace private var slide
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            segment("New task", .new)
            segment("Library", .library)
        }
        .padding(3)
        .frame(width: 260)
        // Crisp edges, no soft shadow in Dark (2026-11-13, the user's call:
        // grey on grey with a shadow looked blurry): a sunk track with a
        // hairline, the pick a clearly lighter pill with its own fine edge.
        .background(Color(light: "EFEFF4", dark: "16191D"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(light: "E5E5EA", dark: "30353D"), lineWidth: 1))
        .sensoryFeedback(.selection, trigger: tab)
    }

    private func segment(_ name: String, _ value: NewTaskTab) -> some View {
        Button { onSelect(value) } label: {
            Text(name)
                .font(Typography.font(15, weight: .semibold))
                .foregroundStyle(tab == value
                                 ? Color(light: "15231A", dark: "F2F3F5")
                                 : Color(light: "6B7280", dark: "8C929C"))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    if tab == value {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(light: "F8F9FA", dark: "343943"))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color(light: "E0E0E5", dark: "4A505A"), lineWidth: 0.75))
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "tab", in: slide)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

/// New task's Library tab: the chore list (`TaskTemplate.all`), one list, no
/// kinds (2026-11-05: six kinds of ideas were replaced by the user's master
/// chore list). Taking one opens the New task tab with its name, Repeat and
/// What to do filled in. All seven always show, even one already on that day
/// (the user's call).
struct TaskPicker: View {
    @ObservedObject var child: Child
    var day: Date
    var onPick: (TaskTemplate) -> Void

    private var chores: [TaskTemplate] { TaskTemplate.picks(age: child.age) }

    var body: some View {
        let chores = chores
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if chores.isEmpty {
                    Text("Every chore is already on \(child.name)'s list for this day.")
                        .font(Typography.font(14.5, weight: .medium))
                        .foregroundStyle(Neutral.secondary)
                        .padding(.top, 18)
                } else {
                    PickGroup(heading: "Chores", items: chores,
                              symbol: { $0.symbol }, title: { $0.title },
                              onPick: onPick)
                        .padding(.top, 12)
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
    }

}

/// A picked-list row's icon: the drawn picture when there is one (the chores,
/// a few habits; `HabitArt`), on its own with no circle, else the symbol in a
/// plain ring. Lists of these sit on the page with hairlines, no grey box
/// (the user's call, 2026-11-05).
struct PickIcon: View {
    var title: String
    var symbol: String

    var body: some View {
        if HabitArt.has(title) {
            HabitArt(title: title)
                .frame(width: 38, height: 38)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Neutral.ink)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(Neutral.border, lineWidth: 1.5))
        }
    }
}
