import SwiftUI

// Ported 1:1 from evlin-style-guide.html's :root tokens — "Design System v2".
// Brand soul: green & white, anchored to the mascot's own green (#3FCE64).
// Parent mode = calm: white ground, green accent, Plus Jakarta only, flat pills, no pops.
// Kid/teen mode = playful: Baloo 2 headers, chunky elevated pills, warm pops allowed.
enum Brand {
    // Green — the brand
    static let greenTint = Color(light: "E4F8E9", dark: "17301F")
    static let greenLight = Color(hex: "8CE6A4")
    static let green = Color(hex: "3FCE64")       // mascot green — primary brand color
    static let greenDeep = Color(hex: "25924A")   // button base / 3D lift / status text
    static let greenInk = Color(hex: "0D3318")
    static let emerald = Color(hex: "3FCE64")     // primary button on the mode picker (mascot green)
    static let emeraldInk = Color(light: "182C20", dark: "CDEFD6", warm: "DDEBD3")  // text on mint (dark text)
    static let mint = Color(light: "D0F1C9", dark: "21392A", warm: "2D4636")        // secondary button fill on the mode picker (soft mint)

    // Pops — warm accents, kid/teen home & earning screens ONLY. Never in parent mode.
    static let popRaspberry = Color(hex: "D91656") // "do this next"
    static let popPink = Color(hex: "EE66A6")
    static let popYellow = Color(hex: "FFEB55")    // always paired with dark text

    // Neutrals
    static let surface = Color(light: "F7F5F0", dark: "262A30")
    static let surfaceSoft = Color(light: "FBFDFB", dark: "1C1F24")
    static let cream = Color(hex: "F7F9F7")       // mode picker ground
    static let card = Color(light: "F6F9F5", dark: "262A30")
    static let line = Color(light: "E2E5EA", dark: "353A42")
    static let ink = Color(light: "15231A", dark: "E4E4E6", warm: "E6E8EC")
    static let inkSoft = Color(light: "8A978D", dark: "8E9A91", warm: "A0A6B0")
}

// Kid/tablet-mode palette. First ported 1:1 from Evlin_Tablet_view/index.html's
// muted cream/sage `const KID = {...}` object — but the app's own design
// system (evlin-style-guide.html) actually specifies a *white* ground for
// kid/teen mode too ("white keeps it from feeling babyish, so it ages up"),
// with the one mascot green as the constant thread tying both modes
// together, and warm "pop" accents (raspberry/pink/yellow) used sparingly
// for "do next" tags and reward moments — never as a flat background wash.
// Realigned to that spec: near-white ground, cards in true white with a
// colored border/shadow for definition (see KidAccent below), same mascot
// green as parent mode rather than a separately-tuned "kid green."
/// The calm palette for the parent's goal and template screens: white,
/// cool grays and one navy, with dark text at high contrast (secondary text
/// still clears 7:1 on white). Colour beyond these only says something:
/// green for approved, red for not approved.
enum Neutral {
    static let navy = Color(hex: "1E2A44")
    static let ink = Color(light: "0F172A", dark: "E4E4E6")
    static let secondary = Color(light: "475569", dark: "A1A1AA")
    // A step deeper than the cool grey page (2026-11-14; #E4E0D5 on
    // Alabaster, #EFECE5 on the cream before).
    static let tile = Color(light: "EFEFF4", dark: "2C3037")
    // Firm on the cool grey page (#DCD7CC on Alabaster, #E5E1D9 before).
    static let line = Color(light: "E5E5EA", dark: "353A42")
    static let border = Color(light: "D1D1D6", dark: "4A505A")
}

enum KidTheme {
    // The kid's side: cream e-paper by day; a warm night e-paper with the
    // iPad in dark mode (2026-11-09; oatmeal #ECE7DF and always-light before).
    static let ink = Color(light: "2B2723", warm: "E6E8EC")
    static let cream = Color(light: "FAF9F6", warm: "262A30")   // cards: the page's off-white, edged by `line`
    static let line = Color(light: "DDD6CB", warm: "353A42")    // a card's edge
    static let green = Brand.green
    static let greenDeep = Brand.greenDeep
    static let greenSoft = Color(light: "E4F8E9", warm: "1F3328")
    static let greenTint = Color(light: "E4F8E9", warm: "1F3328")
    // The tab bar's pick: green by day, off-white at night (2026-11-13,
    // the user's call: the green Tasks tab read as neon).
    static let tabTint = Color(light: "25924A", warm: "E6E8EC")
    static let lavender = Color(light: "EDE7FB", warm: "3B3446")
    static let lavenderText = Color(light: "7C5CD9", warm: "C9B9F2")
    static let muted = Color(light: "E6E0D6", warm: "2C3037")
    static let mutedBorder = Color(light: "D3CBBE", warm: "414650")
    static let inkSoft = Color(light: "7E766C", warm: "A0A6B0")
    /// The page: off-white, as the parent's (2026-11-14; e-paper #F1EFE9
    /// before). `EPaperBackground` where it's a whole screen.
    static let background = Color(light: "FAF9F6", warm: "1C1F24")
    /// The kid's main button: flat (2026-11-15, the user's call: 2D, no
    /// raised base), the start screen's Parent green, the mascot #3FCE64, as
    /// setup's main button, by day and at night, with white words (the main
    /// app's #2FA84F / #3A9257 earlier the same day; iOS's #34C759
    /// and the mascot #3FCE64 raised on a #25924A base earlier the same day;
    /// #41A85C with a #2F7F45 base, and a pale sage paper, #D9E5CF with
    /// #26422C words, before that).
    /// Since 2026-11-16 (the user's call: one button look across setup and
    /// the kid's side): setup's soft mid green, #34B85A (#3A9257 at
    /// night), with semibold white words (`KidTheme.buttonFont`); the
    /// mascot #3FCE64 with heavy rounded words before.
    static let paperButton = OnboardingV2Theme.Palette.button
    static let paperButtonEdge = OnboardingV2Theme.Palette.button
    static let paperButtonBase = Color(light: "25924A", warm: "25924A")
    static let paperInk = Color(light: "FFFFFF", warm: "FFFFFF")
    /// The kid's button words: setup's, Jakarta semibold.
    static func buttonFont(_ size: CGFloat) -> Font { Typography.font(size, weight: .semibold) }
}

// A small rotating palette of bright, saturated hues for per-task color
// variety in kid mode (icon chips, ring slices) — distinct from
// the three reserved "pop" accents in `Brand` (raspberry/pink/yellow), which
// the style guide keeps specifically for "do next" tags and reward moments,
// not general decoration.
enum KidAccent {
    static let palette: [Color] = [
        Color(hex: "3B82F6"), // blue
        Color(hex: "F97316"), // orange
        Color(hex: "A855F7"), // purple
        Color(hex: "EC4899"), // pink
        Color(hex: "14B8A6"), // teal
    ]
    static func color(for index: Int) -> Color { palette[index % palette.count] }
}

// Parent-mode semantic aliases — kept separate from `Brand` so screen code
// reads by role ("primary text", "danger") rather than raw palette names.
enum EColor {
    static let primary = Brand.ink
    static let primaryContainer = Brand.greenTint
    static let secondary = Brand.greenDeep
    static let secondaryContainer = Brand.greenTint
    static let tertiaryContainer = Color(light: "FFF3E0", dark: "3A2A12")
    /// The app's one page colour, on both sides and in setup: off-white,
    /// #FAF9F6 (2026-11-14, the user's call; an ultra-light cool grey,
    /// #F3F4F6, and Alabaster, #EDEAE0, earlier the same day; a warm cream,
    /// #F7F5F0, before), or in Dark (Settings, Appearance; parent
    /// side only) the blue charcoal, #1C1F24 (2026-11-12, the user's call).
    /// Cards are the page's own colour, set apart by an edge or shadow.
    static let surface = Color(light: "FAF9F6", dark: "1C1F24")
    /// A card on the page: the page's own grey, set apart by an edge or
    /// shadow, never lighter (2026-11-14, the user's call: the cream
    /// #F7F5F0 on Alabaster read as white and burned the eyes).
    static let card = Color(light: "FAF9F6", dark: "262A30")
    static let surfaceContainerLowest = Color(light: "FAF9F6", dark: "262A30")
    /// A chip or bar on the page: Apple's light grey, #F2F2F7 (Settings'
    /// page), with a fine edge (2026-11-15, the user's call, after Gemini's
    /// and Apple's: #E8EAEE with a #C9CED6 edge was too much grey), never lighter (2026-11-14: New habit's prizes, Chat's
    /// suggestions and its message bar).
    static let chip = Color(light: "F2F2F7", dark: "262A30")
    static let chipEdge = Color(light: "DCDCE1", dark: "3A3F48")
    /// A dark fill that carries white on it in both appearances (the
    /// floating +, a dark pill): ink by day, a raised grey at night.
    static let inkFill = Color(light: "15231A", dark: "414650")
    static let surfaceContainerHigh = Color(light: "EFEFF4", dark: "30343B")
    static let onSurface = Brand.ink
    static let onSurfaceVariant = Brand.inkSoft
    static let onPrimary = Color.white
    static let outline = Brand.inkSoft
    static let outlineVariant = Brand.line
    static let success = Brand.greenDeep
    /// Red for words and icons. Softer in Dark, where full red glares.
    static let danger = Color(light: "D32F2F", dark: "E06C62")
    /// A red button and the words on it: solid red by day; in Dark a muted
    /// red, a little softer than by day, with near-white words.
    static let dangerFill = Color(light: "D32F2F", dark: "A8433B")
    static let onDangerFill = Color(light: "FFFFFF", dark: "FBEDEB")
    /// The dim behind a floating card: deeper in Dark, so the card stands out.
    static let scrim = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.6) : UIColor(white: 0, alpha: 0.32) })
    /// A card floating over the page: a step lighter than a card in Dark.
    static let raised = Color(light: "FAF9F6", dark: "252527")
}

enum EShadow {
    static let premium = Color.black.opacity(0.04)
    static let premiumRadius: CGFloat = 18
    static let premiumY: CGFloat = 8
}

// Font wrapper around the bundled Plus Jakarta Sans weights (parent mode +
// body text everywhere) — falls back to the system font automatically if a
// name doesn't resolve on device.
enum Typography {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .black, .heavy: name = "PlusJakartaSans-ExtraBold"
        case .bold: name = "PlusJakartaSans-Bold"
        case .semibold: name = "PlusJakartaSans-SemiBold"
        case .medium: name = "PlusJakartaSans-Medium"
        default: name = "PlusJakartaSans-Regular"
        }
        return .custom(name, size: size)
    }

    // Baloo 2 — display font for kid/teen screens only (headers, big numbers,
    // button labels). Never used in parent mode per the style guide.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .black, .heavy: name = "Baloo2-ExtraBold"
        case .bold: name = "Baloo2-Bold"
        case .semibold: name = "Baloo2-SemiBold"
        default: name = "Baloo2-Medium"
        }
        return .custom(name, size: size)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension Color {
    /// One colour for light and one for dark, picked by the screen's own
    /// appearance. The kid's side is always light (Info.plist), so only
    /// the parent's side ever shows the dark one.
    init(light: String, dark: String) {
        let l = UIColor(Color(hex: light)), d = UIColor(Color(hex: dark))
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    /// As above, with a third colour for the warm night (`WarmNight`): the
    /// kid's side and the iPad's start screen in dark mode.
    init(light: String, dark: String, warm: String) {
        let l = UIColor(Color(hex: light)), d = UIColor(Color(hex: dark)), w = UIColor(Color(hex: warm))
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? (WarmNight.on ? w : d) : l })
    }

    /// Light, else the warm night (the kid's tokens, which never show the
    /// parent's neutral dark).
    init(light: String, warm: String) { self.init(light: light, dark: warm, warm: warm) }
}

/// The kid's side, and the iPad's start screen, in dark mode: not black but a
/// warm night e-paper, as an e-reader's night mode (2026-11-09, the user's
/// call): a warm cocoa-grey page, warm cream words, sage buttons. Set by
/// `RootView` for the tablet side and for an iPad that hasn't picked a side
/// yet; the parent's iPhone keeps its neutral dark.
enum WarmNight {
    static var on = false
}

/// The parent's choice in Settings > Appearance: Cream (the default) or Dark
/// (Auto, following the phone, was removed, 2026-11-07). Parent side only: the
/// kid's side, onboarding and the start screens are always Cream (RootView).
/// Dark follows the user's notes: #121212 page, #1E1E1E cards, #E4E4E6 text
/// (not pure white), greens a little calmer so they don't glow.
enum Appearance: String, CaseIterable, Identifiable {
    case cream, dark
    var id: String { rawValue }
    static let key = "evlin.appearance"
    var name: String {
        switch self {
        case .cream: return "Cream"
        case .dark: return "Dark"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .cream: return .light
        case .dark: return .dark
        }
    }
}
