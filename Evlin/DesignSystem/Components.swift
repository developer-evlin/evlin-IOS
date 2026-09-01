import SwiftUI

// Material-Symbols-name -> SF Symbol mapping, so we didn't need to bundle
// another icon font. Covers every icon name used across the ported screens.
enum EIcon {
    static func sf(_ materialName: String) -> String {
        if materialName.hasPrefix("sf:") {
            return String(materialName.dropFirst(3))
        }
        switch materialName {
        case "search": return "magnifyingglass"
        case "bookmark": return "bookmark"
        case "auto_stories": return "book.pages"
        case "style": return "square.stack"
        case "arrow_forward": return "arrow.right"
        case "close": return "xmark"
        case "check": return "checkmark"
        case "favorite": return "heart.fill"
        case "psychology": return "brain.head.profile"
        case "shield": return "shield.fill"
        case "handshake": return "hands.clap.fill"
        case "trending_up": return "chart.line.uptrend.xyaxis"
        case "smartphone": return "iphone"
        case "waves": return "water.waves"
        case "self_improvement": return "figure.mind.and.body"
        case "chat_bubble": return "bubble.left.fill"
        case "home": return "house.fill"
        case "calendar_month": return "calendar"
        case "settings": return "gearshape.fill"
        case "notifications": return "bell.fill"
        case "add": return "plus"
        case "sports_soccer": return "figure.soccer"
        case "music_note": return "music.note"
        case "menu_book": return "book.closed.fill"
        case "dinner_dining": return "fork.knife"
        case "task_alt": return "checkmark.circle.fill"
        case "priority_high": return "exclamationmark.circle.fill"
        case "schedule": return "clock.fill"
        case "pan_tool": return "hand.raised.fill"
        case "lock": return "lock.fill"
        case "lock_open": return "lock.open.fill"
        case "play_arrow": return "play.fill"
        case "alt_route": return "arrow.triangle.branch"
        case "apps": return "square.grid.2x2.fill"
        case "arrow_back": return "arrow.left"
        case "arrow_upward": return "arrow.up"
        case "auto_awesome": return "sparkles"
        case "autorenew": return "arrow.triangle.2.circlepath"
        case "bedtime": return "bed.double.fill"
        case "block": return "nosign"
        case "bolt": return "bolt.fill"
        case "camera_alt": return "camera.fill"
        case "check_circle": return "checkmark.circle.fill"
        case "chevron_left": return "chevron.left"
        case "chevron_right": return "chevron.right"
        case "dark_mode": return "moon.fill"
        case "delete": return "trash.fill"
        case "diversity_3": return "person.3.fill"
        case "edit": return "pencil"
        case "edit_note": return "square.and.pencil"
        case "expand_more": return "chevron.down"
        case "fitness_center": return "figure.strengthtraining.traditional"
        case "gavel": return "hammer.fill"
        case "graph_4": return "chart.bar.fill"
        case "group": return "person.2.fill"
        case "help": return "questionmark.circle.fill"
        case "info": return "info.circle.fill"
        case "location_on": return "mappin.and.ellipse"
        case "more_horiz": return "ellipsis"
        case "more_vert": return "ellipsis"
        case "notes": return "note.text"
        case "person": return "person.fill"
        case "photo_camera": return "camera.fill"
        case "play_circle": return "play.circle.fill"
        case "quiz": return "questionmark.circle.fill"
        case "replay": return "arrow.clockwise"
        case "smart_display": return "play.rectangle.fill"
        case "sync_alt": return "arrow.left.arrow.right"
        case "timer": return "timer"
        case "warning": return "exclamationmark.triangle.fill"
        case "wb_sunny": return "sun.max.fill"
        default: return "circle.fill"
        }
    }
}

struct Icon: View {
    var name: String
    var size: CGFloat = 18
    var color: Color = EColor.onSurface

    var body: some View {
        Image(systemName: EIcon.sf(name))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    var padded: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padded ? 20 : 0)
            .background(EColor.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(EColor.outlineVariant.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: EShadow.premium, radius: EShadow.premiumRadius, y: EShadow.premiumY)
    }
}

struct SectionHead<Right: View>: View {
    var title: String
    @ViewBuilder var right: Right

    init(_ title: String, @ViewBuilder right: () -> Right = { EmptyView() }) {
        self.title = title
        self.right = right()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(Typography.font(20, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
            Spacer()
            right
        }
        .padding(.bottom, 10)
    }
}

struct GlassHeader<Right: View>: View {
    var title: String
    @ViewBuilder var right: Right

    init(_ title: String, @ViewBuilder right: () -> Right = { EmptyView() }) {
        self.title = title
        self.right = right()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(Typography.font(28, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
            Spacer()
            right
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct HeaderIconButton: View {
    var iconName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Icon(name: iconName, size: 18, color: EColor.onSurface)
                .frame(width: 38, height: 38)
                .background(EColor.surfaceContainerLowest)
                .clipShape(Circle())
                .shadow(color: EShadow.premium, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct EToggle: View {
    @Binding var on: Bool
    var color: Color = Brand.green

    var body: some View {
        Capsule()
            .fill(on ? color : Color(hex: "E9E9EA"))
            .frame(width: 51, height: 31)
            .overlay(
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .padding(2)
                    .offset(x: on ? 10 : -10)
            )
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { on.toggle() } }
    }
}

struct PrimaryButton: View {
    var title: String
    var systemIcon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typography.font(15, weight: .bold))
                if let systemIcon {
                    Image(systemName: systemIcon).font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Brand.greenDeep)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Pill: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(Typography.font(9, weight: .bold))
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }
}

struct InitialsAvatar: View {
    var name: String
    var size: CGFloat = 28

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }

    var body: some View {
        Text(initials)
            .font(Typography.font(size * 0.4, weight: .bold))
            .foregroundStyle(EColor.primary)
            .frame(width: size, height: size)
            .background(EColor.primaryContainer)
            .clipShape(Circle())
    }
}
