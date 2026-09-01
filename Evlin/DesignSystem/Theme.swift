import SwiftUI

// Ported 1:1 from evlin-style-guide.html's :root tokens — "Design System v2".
// Brand soul: green & white, anchored to the mascot's own green (#3FCE64).
// Parent mode = calm: white ground, green accent, Plus Jakarta only, flat pills, no pops.
// Kid/teen mode = playful: Baloo 2 headers, chunky elevated pills, warm pops allowed.
enum Brand {
    // Green — the brand
    static let greenTint = Color(hex: "E4F8E9")
    static let greenLight = Color(hex: "8CE6A4")
    static let green = Color(hex: "3FCE64")       // mascot green — primary brand color
    static let greenDeep = Color(hex: "25924A")   // button base / 3D lift / status text
    static let greenInk = Color(hex: "0D3318")

    // Pops — warm accents, kid/teen home & earning screens ONLY. Never in parent mode.
    static let popRaspberry = Color(hex: "D91656") // "do this next"
    static let popPink = Color(hex: "EE66A6")
    static let popYellow = Color(hex: "FFEB55")    // always paired with dark text

    // Neutrals
    static let surface = Color.white
    static let surfaceSoft = Color(hex: "FBFDFB")
    static let card = Color(hex: "F6F9F5")
    static let line = Color(hex: "E9EFE8")
    static let ink = Color(hex: "15231A")
    static let inkSoft = Color(hex: "8A978D")
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
enum KidTheme {
    static let ink = Brand.ink
    static let cream = Color.white
    static let line = Color(hex: "E9EFE8")
    static let green = Brand.green
    static let greenDeep = Brand.greenDeep
    static let greenSoft = Brand.greenTint
    static let greenTint = Brand.greenTint
    static let lavender = Color(hex: "EDE7FB")
    static let lavenderText = Color(hex: "7C5CD9")
    static let muted = Color(hex: "F1F1EF")
    static let mutedBorder = Color(hex: "D8DEDA")
    static let inkSoft = Brand.inkSoft
    // Near-white, not flat sage/gray — a card floating on this needs its own
    // border/shadow to read as a card, same as parent mode's Card component.
    static let background = Brand.surfaceSoft
}

// A small rotating palette of bright, saturated hues for per-task color
// variety in kid mode (icon chips, ring slices, comic tiles) — distinct from
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
    static let tertiaryContainer = Color(hex: "FFF3E0")
    static let surface = Brand.surfaceSoft
    static let surfaceContainerLowest = Color.white
    static let surfaceContainerHigh = Color(hex: "F1F1EF")
    static let onSurface = Brand.ink
    static let onSurfaceVariant = Brand.inkSoft
    static let onPrimary = Color.white
    static let outline = Brand.inkSoft
    static let outlineVariant = Brand.line
    static let success = Brand.greenDeep
    static let danger = Color(hex: "D32F2F")
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

// Gradient tokens for the Library's slide-lesson covers — distinct topical
// colors, built from the same green family plus deep neutrals (matches the
// web app's per-lesson gradients; these aren't part of the brand palette
// itself, just themed cover art).
enum EGradient {
    static let anxiousGen = LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "1E1B4B")], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let praise = LinearGradient(colors: [Brand.greenDeep, Brand.greenInk], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tantrum = LinearGradient(colors: [Color(hex: "B45309"), Color(hex: "431407")], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let emotionalIntelligence = LinearGradient(colors: [Color(hex: "1A2B3C"), Color(hex: "041627")], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let digitalBoundaries = LinearGradient(colors: [Brand.greenDeep, Brand.greenInk], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let conflictResolution = LinearGradient(colors: [Color(hex: "6E3900"), Color(hex: "261000")], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let growthMindset = LinearGradient(colors: [Color(hex: "0B1D2D"), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
}
