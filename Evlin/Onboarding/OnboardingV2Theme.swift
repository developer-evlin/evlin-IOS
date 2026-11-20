import SwiftUI

// Onboarding v2 design system — "Informed Sentinel". Ported from the real
// Evlin iOS app's OnboardingV2Theme.swift so the prototype's onboarding flow
// stays visually close to production, while keeping its own token namespace
// (separate from DesignSystem/Theme.swift's EColor/Brand, which is unrelated).

// MARK: - Spacing / corner radius (the target app has no equivalent tokens)

enum Spacing {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
    static let section: CGFloat = 32
    static let page: CGFloat = 40
}

enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let pill: CGFloat = 100
}

enum OnboardingV2Theme {

    enum Palette {
        static let surface = EColor.surface
        static let surfaceLow = Color(light: "F7F8FA", dark: "22252B", warm: "22252B")
        static let surfaceContainer = Color(light: "F1F2F4", dark: "262A30", warm: "262A30")
        // Cards, rows and secondary buttons in setup: the page's off-white,
        // set apart by their edge (2026-11-14; a warm paper, #F8F6F1, on
        // the e-paper before).
        static let surfaceLowest = Color(light: "FAF9F6", dark: "262A30", warm: "262A30")

        static let onSurface = Color(light: "1A1C1E", dark: "E6E8EC", warm: "E6E8EC")
        static let onSurfaceVariant = Color(light: "5A5E66", dark: "A0A6B0", warm: "A0A6B0")
        static let outline = Color(light: "8E9199", dark: "7A808B", warm: "7A808B")
        static let outlineVariant = Color(light: "E5E5EA", dark: "353A42", warm: "353A42")
        /// Fields: a near-white box with a warm hairline and a soft
        /// shadow, so it sits up off the e-paper page. Choice bars: a soft
        /// warm track; the picked one a soft green pill with deep-green
        /// words (2026-11-08: cool pale greys vanished; a darker fill with a
        /// green ring was harsh; a white pick was tucked in and hard to see).
        static let fieldFill = Color(light: "FAF9F6", dark: "262A30", warm: "262A30")
        static let fieldEdge = Color(light: "D1D1D6", dark: "353A42", warm: "353A42")
        // On the off-white page, Apple's light greys; the pick a fresh light
        // green, #C2EDC7 with deep-green #134A26 words, and a faint lift
        // (2026-11-15, the user's call: lighter than the start screen's
        // Child green, #A4E3AA with #0F3A1E words, tried just before as
        // "the same color behind child mode"; a forest green #2F8F50 and the deep #1F6B3A
        // with white words just before, after the pale sage was a "mood
        // killer"; a muted sage
        // #D9EADB with a #BCD9C2 edge and #1B6B34 words just before;
        // the page's off-white as Apple's segmented control, "white isn't
        // the color", a light mint #CBEFCE and the start screen's Child
        // #A4E3AA tried just before;
        // the solid button green with white words, the same day, was harsh; the main app's sage wash with a green edge
        // before that) (2026-11-15, the user's call: the warm #E8E4DB track, #CFC6B6
        // field edge and pale mint pick, made for the e-paper, read muddy).
        static let choiceTrack = Color(light: "EFEFF4", dark: "262A30", warm: "262A30")
        static let choicePicked = Color(light: "C2EDC7", dark: "2F563B", warm: "2F563B")
        static let choicePickedEdge = Color(light: "C2EDC7", dark: "2F563B", warm: "2F563B")
        static let choicePickedText = Color(light: "134A26", dark: "EAF7EC", warm: "EAF7EC")
        /// The e-paper page under onboarding: a matte light warm grey,
        /// grained (`EPaperBackground`); with the device in dark mode, a
        /// warm near-black, since most parents set up at night (2026-11-08).
        static let paper = Color(light: "FAF9F6", dark: "1C1F24", warm: "1C1F24")
        /// The kid's e-paper button (always light: the kid's side is).
        static let paperButton = KidTheme.paperButton
        static let paperButtonEdge = KidTheme.paperButtonEdge
        static let paperButtonBase = KidTheme.paperButtonBase
        static let paperButtonInk = KidTheme.paperInk

        // Straight from evlin-style-guide (1).html's :root token block —
        // "everything builds from that one green at different depths."
        static let greenTint = Color(light: "E4F8E9", dark: "17301F")   // soft fills, banners, done cards
        static let greenLight = Color(hex: "8CE6A4")  // light accents
        static let greenMascot = Color(hex: "3FCE64") // primary brand — buttons, checks, accents
        static let greenDeep = Color(hex: "25924A")   // button 3D base, deeper accents, status text
        static let greenInk = Color(hex: "0D3318")    // dark green text — swap in when a green fill fails contrast

        /// Setup's main buttons, its progress bar, the picked choice and the
        /// ticked boxes, both sides: the soft mid green of the Family
        /// Sharing question's Yes, #34B85A (#3A9257 at night), with white
        /// semibold words (2026-11-16, the user's call: the bright green
        /// buttons hurt the eyes; the start screen's Parent green, the
        /// mascot #3FCE64 (`Brand.emerald`), from 2026-11-15, and the main
        /// app's #2FA84F / #3A9257 and iOS's #34C759 earlier that day).
        /// Since 2026-11-16 (later the same day, the user's call: one green
        /// for the style everywhere) the main app's button green, #2FA84F,
        /// the same as Create task, Add habit and Approve.
        static let button = Color(light: "2FA84F", dark: "3A9257", warm: "3A9257")
        /// Setup's other green fills and accents (the busy button, step
        /// numbers, focused fields, the code entry's Connect): the same.
        static let primary = button
        static let primaryContainer = Color(light: "E8F5E9", dark: "1B3323")
        static let onPrimary = Color.white

        // CTA fill — chartreuse, off style-guide-spec by request. Flat (no
        // 3D base), matching ".btn-parent"; text auto-switches to
        // `greenInk` via isLightFill below since this is far lighter than
        // the guide's mascot green.
        static let ctaFill = Color(hex: "58CC02")

        static let secondary = Color(light: "2E7D32", dark: "3FCE64")
        static let secondaryContainer = Color(light: "E8F5E9", dark: "1B3323")

        static let tertiary = Color(hex: "EF6C00")
        static let tertiaryContainer = Color(light: "FFF3E0", dark: "3A2A12")

        static let error = Color(hex: "D32F2F")
        static let errorContainer = Color(light: "FFEBEE", dark: "3A1E1E")

        static let darkScreen = Color(hex: "0A0A0D")
        static let darkBody = Color(hex: "B9BCC4")
        static let darkCard = Color(hex: "16161B")

        static let deviceBody = Color(hex: "0C0C0E")
        static let deviceRing = Color(hex: "2A2A2E")
    }

    enum Metrics {
        static let deviceCornerRadius: CGFloat = 52
        static let devicePadding: CGFloat = 9
        static let deviceRingWidth: CGFloat = 1.5
        static let screenCornerRadius: CGFloat = 44
        static let screenBodyPaddingTop: CGFloat = 6
        static let screenBodyPaddingHorizontal: CGFloat = 20
        static let screenBodyPaddingBottom: CGFloat = 24

        // Full pill (28 ≈ half of the ~56pt-tall button), matching
        // Onboarding_Evlin/screens.jsx's PrimaryButton (borderRadius: 28).
        static let ctaCornerRadius: CGFloat = 28
        static let ctaPaddingVertical: CGFloat = 18
        static let ctaPaddingHorizontal: CGFloat = 24
        static let ctaRowSpacing: CGFloat = 10
        static let ctaMaxWidth: CGFloat = 600
        static let ctaHeightCompact: CGFloat = 58
        static let ctaHeightRegular: CGFloat = 88

        static let cardCornerRadius: CGFloat = 16
        static let cardPadding: CGFloat = 15
        static let listItemCornerRadius: CGFloat = 14
        static let listItemPaddingVertical: CGFloat = 12
        static let listItemPaddingHorizontal: CGFloat = 13
        static let fieldCornerRadius: CGFloat = 13
        static let fieldPaddingVertical: CGFloat = 14
        static let fieldPaddingHorizontal: CGFloat = 15

        static let pillCornerRadius: CGFloat = 999
        static let phaseTagPaddingVertical: CGFloat = 5
        static let phaseTagPaddingHorizontal: CGFloat = 12

        static let dotSize: CGFloat = 9
        static let dotSpacing: CGFloat = 7
        static let dotActiveScale: CGFloat = 1.3

        // The column onboarding's single-screen steps (and the done/
        // confirm screens and mode picker outside this container) center
        // themselves in on iPad. Started as a literal iPhone-width cap —
        // "looks identical to iPhone, just not stretched" — but that read
        // as a small phone screen floating in the middle of the canvas.
        // Widened once the type/buttons themselves were also scaled up for
        // iPad, so the column is sized for what's actually in it now
        // rather than for an iPhone's own screen width.
        static let iPadCenteredMaxWidth: CGFloat = 620
    }

    // Plus Jakarta Sans (the app-wide body/parent font — see Evlin.Typography
    // in DesignSystem/Theme.swift) instead of the system font, so onboarding
    // matches the rest of the app instead of reading as native iOS chrome.
    //
    // Each size takes a `regular` flag (iPad's horizontalSizeClass, read by
    // the Text.onboardingV2*() modifiers below) and scales up ~40% when
    // true. Capping the column to an iPhone width fixed the edge-to-edge
    // stretch, but left every screen reading as a literal small iPhone
    // sitting in a sea of blank canvas — the same "auto-rendered, not
    // customized" complaint the kid tablet screens had before KidAdaptive
    // scaled *their* type up too, not just capped width. This is that same
    // fix applied here. Only the sizes that actually carry a screen's
    // visual weight (headline, body, primary CTA) scale; small incidental
    // labels (phase tag, step counter, phone-mock label) stay put — bumping
    // genuinely tiny chrome text doesn't read as "bigger," just blurrier.
    enum Typography {
        static func titleXL(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 36 : 25, weight: .bold) }
        static let titleXLTracking: CGFloat = -0.6

        static func titleL(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 27 : 21, weight: .semibold) }
        static let titleLTracking: CGFloat = -0.1

        static func body(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 18 : 13.5, weight: .regular) }
        static let bodyLineSpacing: CGFloat = 13.5 * 0.5

        static func bodyStrong(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 19 : 15, weight: .medium) }
        static let bodyXS = Evlin.Typography.font(11, weight: .regular)
        /// Semibold (2026-11-16, the user's call, with the softer green:
        /// thick white letters on a strong fill tired the eyes; bold before).
        static func cta(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 21 : 15, weight: .semibold) }
        static func ctaBold(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 21 : 15, weight: .heavy) }

        static let phaseTag = Evlin.Typography.font(12, weight: .bold)
        static let phaseTagTracking: CGFloat = 0.2

        static let phoneLabel = Evlin.Typography.font(11, weight: .bold)
        static let phoneLabelTracking: CGFloat = 1.4

        static let counter = Evlin.Typography.font(13, weight: .regular).monospacedDigit()
        static let navButton = Evlin.Typography.font(14, weight: .semibold)
    }

    enum Shadow {
        static let premiumColor = Color.black.opacity(0.05)
        static let premiumRadius: CGFloat = 15
        static let premiumY: CGFloat = 8
    }
}

// MARK: - Per-side accent

enum OnboardingV2Role {
    case parent
    case child

    var label: String { self == .parent ? "PARENT DEVICE" : "KID DEVICE" }

    // Feeds button fills (OnboardingV2PrimaryButton's role: init) and the
    // selected-state border stroke. Same mascot green on both roles now —
    // parent buttons used to sit on a separate chartreuse `ctaFill`.
    var accent: Color {
        OnboardingV2Theme.Palette.button
    }

    var accentContainer: Color {
        self == .parent ? OnboardingV2Theme.Palette.primaryContainer
                        : OnboardingV2Theme.Palette.secondaryContainer
    }
}

// MARK: - Text helpers
//
// Modifiers, not plain Text extension methods — reading
// horizontalSizeClass to pick the iPad-scaled font requires @Environment,
// which only a ViewModifier's own body(content:) can see; a bare
// `extension Text` method has no environment access of its own.

private struct OnboardingV2TitleXLModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    func body(content: Content) -> some View {
        content
            .font(OnboardingV2Theme.Typography.titleXL(hSizeClass == .regular))
            .tracking(OnboardingV2Theme.Typography.titleXLTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }
}

private struct OnboardingV2TitleLModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    func body(content: Content) -> some View {
        content
            .font(OnboardingV2Theme.Typography.titleL(hSizeClass == .regular))
            .tracking(OnboardingV2Theme.Typography.titleLTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }
}

private struct OnboardingV2BodyModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    func body(content: Content) -> some View {
        content
            .font(OnboardingV2Theme.Typography.body(hSizeClass == .regular))
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
            .lineSpacing(OnboardingV2Theme.Typography.bodyLineSpacing)
    }
}

private struct OnboardingV2BodyStrongModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    func body(content: Content) -> some View {
        content
            .font(OnboardingV2Theme.Typography.bodyStrong(hSizeClass == .regular))
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }
}

extension Text {
    func onboardingV2TitleXL() -> some View { modifier(OnboardingV2TitleXLModifier()) }
    func onboardingV2TitleL() -> some View { modifier(OnboardingV2TitleLModifier()) }
    func onboardingV2Body() -> some View { modifier(OnboardingV2BodyModifier()) }
    func onboardingV2BodyStrong() -> some View { modifier(OnboardingV2BodyStrongModifier()) }

    // Small incidental chrome (helper captions, inline hints) — stays
    // iPhone-sized on purpose, see the Typography enum's own comment.
    func onboardingV2BodyXS() -> some View {
        self.font(OnboardingV2Theme.Typography.bodyXS)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

// MARK: - Primary CTA (`.cta` / `.cta.green`)

struct OnboardingV2PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var fill: Color = OnboardingV2Theme.Palette.ctaFill
    // Style guide: ".btn-kid" gets a solid 3D-lift base (green-deep), while
    // ".btn-parent" is "flat pill" — same green, no base. Flat by default
    // since every existing call site is either a role-based (parent/child)
    // or a plain non-brand button (Apple/Google), neither of which used a
    // hard offset shadow before; role: below opts child in explicitly.
    var flat: Bool = true
    /// The kid's e-paper button: pale sage paper, deep green ink, a fine
    /// edge and a soft paper base (2026-11-09, the user's call: warm, easy
    /// on the eyes, nothing glaring on the kid's iPad).
    var paper: Bool = false
    let action: () -> Void

    // Drives disabled dimming from inside the button itself (see body)
    // instead of callers chaining their own `.opacity()` on top — that used
    // to fade the 3D-lift base and the main pill together, and since they're
    // two separate overlapping shapes, the result was a smeared double pill
    // rather than one grayed-out button.
    @Environment(\.isEnabled) private var isEnabled
    @State private var tapCount = 0
    // The single most visible "this still looks like a phone" tell on
    // iPad — a CTA sized for a 44pt iPhone touch target reads as tiny
    // floating in the middle of a 1024pt-wide canvas. Taller + bigger
    // label on regular width, same pill shape.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }
    // Keeps the pill looking like a pill instead of a rounded rectangle
    // once the taller padding above roughly doubles the button's height —
    // a fixed corner radius sized for the iPhone height reads noticeably
    // less rounded at the taller iPad size.
    private var cornerRadius: CGFloat { isRegular ? OnboardingV2Theme.Metrics.ctaCornerRadius + 10 : OnboardingV2Theme.Metrics.ctaCornerRadius }

    init(_ title: String,
         systemImage: String? = nil,
         fill: Color = OnboardingV2Theme.Palette.ctaFill,
         flat: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.fill = fill
        self.flat = flat
        self.action = action
    }

    init(_ title: String,
         systemImage: String? = nil,
         role: OnboardingV2Role,
         action: @escaping () -> Void) {
        // Same fill/text color on both roles, but the 3D-lift base
        // (green-deep, box-shadow: 0 5px 0 var(--green-deep)) stays
        // kid-only — that tactile "pressable button" feel is a kid-mode
        // thing; parent buttons stay a flat pill.
        // One button for both sides (2026-11-14, the user's call: "just make
        // it the same button"): the parent's flat green pill. The child's
        // raised paper button before, a different green.
        self.init(title, systemImage: systemImage, fill: role.accent, flat: true, action: action)
    }

    var body: some View {
        Button {
            tapCount += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            // Kid-mode buttons (the 3D-lift ".btn-kid" style, `flat: false`)
            // get a heavier weight than the flat parent-mode pill — reads
            // bolder/punchier for a kid audience, matching the chunkier
            // mascot-UI feel used elsewhere in kid mode.
            .font(flat ? OnboardingV2Theme.Typography.cta(isRegular) : OnboardingV2Theme.Typography.ctaBold(isRegular))
            // A translucent version of the brand green (the old approach —
            // fill and text both faded via `.opacity`) washes out to almost
            // nothing against a light background, so a disabled button
            // barely read as a button at all. A solid neutral fill with
            // full-strength gray text is the standard disabled-button
            // convention — it stays a clearly defined pill, just inert.
            .foregroundStyle(!isEnabled ? OnboardingV2Theme.Palette.onSurfaceVariant
                             : paper ? OnboardingV2Theme.Palette.paperButtonInk : OnboardingV2Theme.Palette.onPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
            .background(
                ZStack {
                    // The 3D-lift "base" is a solid offset duplicate of the
                    // pill shape sitting behind the face — not a `.shadow()`
                    // modifier, which would render a shadow of the *label
                    // text* too (a `.shadow` on this view sees everything
                    // above it, text included, producing a ghosted second
                    // copy of the button's own words offset below it).
                    // Dropped while disabled, along with the fill swap below
                    // — a second overlapping shape has nothing to blend into
                    // once the button reads as one flat gray pill.
                    if !flat && isEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(paper ? OnboardingV2Theme.Palette.paperButtonBase : OnboardingV2Theme.Palette.greenDeep)
                            .offset(y: paper ? 4 : 5)
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isEnabled ? (paper ? OnboardingV2Theme.Palette.paperButton : fill) : OnboardingV2Theme.Palette.choiceTrack)
                    if paper && isEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(OnboardingV2Theme.Palette.paperButtonEdge, lineWidth: 1)
                    }
                }
                // Flattens the two overlapping rectangles into one rendered
                // layer before anything else (a press-state dim, a future
                // `.opacity()`) gets applied — without this, any modifier
                // that fades the button fades each rectangle independently,
                // and the seam between them shows through as a smeared
                // double edge. With it, dimming always applies to the
                // already-composited single shape instead.
                .compositingGroup()
            )
            .frame(height: isRegular ? OnboardingV2Theme.Metrics.ctaHeightRegular : OnboardingV2Theme.Metrics.ctaHeightCompact)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .frame(maxWidth: OnboardingV2Theme.Metrics.ctaMaxWidth)
        .frame(maxWidth: .infinity)
    }

}

// MARK: - Secondary / back affordance (`.cta-secondary`)

struct OnboardingV2SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    /// The icon's own colour (the words keep the page's ink).
    var imageTint: Color? = nil
    let action: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var tapCount = 0
    private var isRegular: Bool { hSizeClass == .regular }

    init(_ title: String,
         systemImage: String? = nil,
         imageTint: Color? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.imageTint = imageTint
        self.action = action
    }

    var body: some View {
        Button {
            tapCount += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(imageTint ?? OnboardingV2Theme.Palette.onSurface)
                }
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta(isRegular))
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: isRegular ? OnboardingV2Theme.Metrics.ctaCornerRadius + 10 : OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    // The page's card colour: white by day, the card at night
                    // (plain white glared and hid its words on the warm night).
                    .fill(OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isRegular ? OnboardingV2Theme.Metrics.ctaCornerRadius + 10 : OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
            .frame(height: isRegular ? OnboardingV2Theme.Metrics.ctaHeightRegular : OnboardingV2Theme.Metrics.ctaHeightCompact)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .frame(maxWidth: OnboardingV2Theme.Metrics.ctaMaxWidth)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Phase tag (`.phase-tag`)

struct OnboardingV2PhaseTag: View {
    let phase: String

    init(_ phase: String) { self.phase = phase }

    var body: some View {
        Text(phase)
            .font(OnboardingV2Theme.Typography.phaseTag)
            .tracking(OnboardingV2Theme.Typography.phaseTagTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .padding(.vertical, OnboardingV2Theme.Metrics.phaseTagPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.phaseTagPaddingHorizontal)
            .background(
                Capsule().fill(OnboardingV2Theme.Palette.primaryContainer)
            )
    }
}

// MARK: - Step counter (`.counter`)

struct OnboardingV2StepCounter: View {
    let index: Int
    let total: Int
    var labeled: Bool = true

    init(index: Int, total: Int, labeled: Bool = true) {
        self.index = index
        self.total = total
        self.labeled = labeled
    }

    var body: some View {
        Text(labeled ? "Step \(index) of \(total)" : "\(index) / \(total)")
            .font(OnboardingV2Theme.Typography.counter)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

// MARK: - Bottom dots progress nav (`.dots-nav`)

struct OnboardingV2DotsNav: View {
    let count: Int
    let current: Int
    var activeColor: Color = OnboardingV2Theme.Palette.ctaFill
    var onSelect: ((Int) -> Void)? = nil

    init(count: Int, current: Int, activeColor: Color = OnboardingV2Theme.Palette.ctaFill, onSelect: ((Int) -> Void)? = nil) {
        self.count = count
        self.current = current
        self.activeColor = activeColor
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: OnboardingV2Theme.Metrics.dotSpacing) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == current
                Circle()
                    .fill(on ? activeColor
                             : OnboardingV2Theme.Palette.outlineVariant)
                    .frame(width: OnboardingV2Theme.Metrics.dotSize,
                           height: OnboardingV2Theme.Metrics.dotSize)
                    .scaleEffect(on ? OnboardingV2Theme.Metrics.dotActiveScale : 1)
                    .animation(.easeInOut(duration: 0.2), value: current)
                    .onTapGesture { onSelect?(i) }
            }
        }
    }
}

// MARK: - Card (`.card`)

struct OnboardingV2Card<Content: View>: View {
    var dark: Bool = false
    @ViewBuilder var content: () -> Content

    init(dark: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.dark = dark
        self.content = content
    }

    var body: some View {
        content()
            .padding(OnboardingV2Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .fill(dark ? OnboardingV2Theme.Palette.darkCard
                               : OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                dark
                ? RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                   style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                : nil
            )
            .shadow(color: dark ? .clear : OnboardingV2Theme.Shadow.premiumColor,
                    radius: dark ? 0 : OnboardingV2Theme.Shadow.premiumRadius,
                    x: 0,
                    y: dark ? 0 : OnboardingV2Theme.Shadow.premiumY)
    }
}

// MARK: - Phone-screen container (`.iphone` + `.screen` + `.screen-body`)

struct OnboardingV2ScreenContainer<Content: View, Footer: View>: View {

    let role: OnboardingV2Role
    let phase: String
    let stepIndex: Int
    let stepTotal: Int
    let title: String
    var subtitle: String? = nil
    var dark: Bool = false
    var showsDeviceFrame: Bool = false
    var dotsCount: Int? = nil
    var dotsCurrent: Int? = nil
    // Small icon-only back button pinned to the top-leading corner of the
    // screen — replaces the old text "‹ Back" link that used to sit in the
    // footer on every step (OnboardingV2BackLink, now unused). nil hides it,
    // matching how the old link only rendered `if let onBack`.
    var onBack: (() -> Void)? = nil
    /// A scroll bar that stays in view, for a step that's a long list to
    /// scroll (2026-11-12, the user's ask: the Family Sharing steps).
    var scrollBar: Bool = false

    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    // This container is the one thing every onboarding step (parent and
    // child chains alike) renders through, so it's the one place that
    // needs to know about iPad at all. Without this, the screen just
    // stretched this iPhone-shaped form (fields, single-column copy, a
    // full-width CTA) edge to edge across the iPad's much wider window —
    // the same "auto-rendered" look the tablet kid screens had before
    // their own iPad pass, just here on a design that's meant to read as
    // one phone-width screen, not scale up into a bigger one. So instead
    // of scaling typography/spacing up like the kid side did, this caps
    // the content at a real iPhone's width and centers it — the flow
    // should look identical to iPhone, just not stretched.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    init(role: OnboardingV2Role,
         phase: String,
         stepIndex: Int,
         stepTotal: Int,
         title: String,
         subtitle: String? = nil,
         dark: Bool = false,
         showsDeviceFrame: Bool = false,
         dotsCount: Int? = nil,
         dotsCurrent: Int? = nil,
         onBack: (() -> Void)? = nil,
         scrollBar: Bool = false,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.role = role
        self.phase = phase
        self.stepIndex = stepIndex
        self.stepTotal = stepTotal
        self.title = title
        self.subtitle = subtitle
        self.dark = dark
        self.showsDeviceFrame = showsDeviceFrame
        self.dotsCount = dotsCount
        self.dotsCurrent = dotsCurrent
        self.onBack = onBack
        self.scrollBar = scrollBar
        self.content = content
        self.footer = footer
    }

    private func backButton() -> some View {
        Button(action: onBack!) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(dark ? Color.white : OnboardingV2Theme.Palette.onSurfaceVariant)
                // Icon reads small on purpose; the frame is the real
                // hit target so it's still comfortable to tap. The plain
                // style only counts drawn pixels, so the shape says so.
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // One column, not a split — a left pane only had something to show on
    // steps that actually pass a title into this container, and most of
    // this flow draws its own heading *inside* content() instead (a QR
    // step's "Pair Your Child's Device," an app-picker step's "Choose Apps
    // to Lock," …). On those, the left pane had nothing but the bare
    // "Evlin" wordmark and a phase tag — dead space next to the screen's
    // actual heading, not a second meaningful region. Single centered
    // column, sized for iPad (wider cap, same bigger type/buttons from the
    // scale-up pass) instead of trying to either split the screen or hold
    // it to an iPhone's own width.
    private var screenBody: some View { screenBody(pinned: false) }

    /// The progress bar and Back button.
    @ViewBuilder private var topChrome: some View {
        ProgressView(value: Double(min(stepIndex, stepTotal)), total: Double(max(1, stepTotal)))
            .progressViewStyle(LinearProgressViewStyle(tint: role.accent))
            .padding(.bottom, Spacing.xs)

        if onBack != nil {
            backButton().padding(.bottom, Spacing.xs)
        }
    }

    /// `pinned`: the top chrome and the footer are drawn by the caller, fixed
    /// above and below a scrolling middle (iPhone, see `body`).
    private func screenBody(pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if !pinned { topChrome }

            // Centered headline + body, matching the reference flow's
            // icon-then-bold-statement-then-detail pattern. PARENT ONLY —
            // this container is shared with the child flow, and centering
            // unconditionally here leaked the parent redesign onto child
            // screens that were never asked to change.
            //
            // Screens that pass an empty title (most of the flow now, save
            // for PIN and legal-document steps) skip this block entirely
            // rather than rendering blank headline space.
            if !title.isEmpty {
                VStack(alignment: role == .parent ? .center : .leading, spacing: Spacing.md) {
                    Text(title)
                        .onboardingV2TitleL()
                        .multilineTextAlignment(role == .parent ? .center : .leading)
                        .foregroundStyle(dark ? Color.white
                                              : OnboardingV2Theme.Palette.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .onboardingV2Body()
                            .multilineTextAlignment(role == .parent ? .center : .leading)
                            .foregroundStyle(dark ? OnboardingV2Theme.Palette.darkBody
                                                  : OnboardingV2Theme.Palette.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: role == .parent ? .center : .leading)
            }

            // Keep each step between the top progress/navigation and the
            // bottom action on iPad too, using the available screen height.
            if isRegular {
                Spacer(minLength: Spacing.lg)

                content()

                Spacer(minLength: Spacing.lg)

                if !pinned {
                    VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        footer()
                    }
                }
            } else {
                Spacer(minLength: Spacing.lg)

                content()

                Spacer(minLength: Spacing.lg)

                if !pinned {
                    VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        footer()
                    }
                }
            }
        }
        .padding(.top, pinned ? 0 : OnboardingV2Theme.Metrics.screenBodyPaddingTop)
        .padding(.horizontal, isRegular ? 32 : OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
        .padding(.bottom, pinned ? 0 : OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRegular ? .center : .top)
        .background { if dark { OnboardingV2Theme.Palette.darkScreen } else { EPaperBackground() } }
    }

    var body: some View {
        Group {
            if showsDeviceFrame {
                screenBody
                    .clipShape(RoundedRectangle(
                        cornerRadius: OnboardingV2Theme.Metrics.screenCornerRadius,
                        style: .continuous))
                    .padding(OnboardingV2Theme.Metrics.devicePadding)
                    .background(
                        RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.deviceCornerRadius,
                                         style: .continuous)
                            .fill(OnboardingV2Theme.Palette.deviceBody)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.deviceCornerRadius,
                                         style: .continuous)
                            .stroke(OnboardingV2Theme.Palette.deviceRing,
                                    lineWidth: OnboardingV2Theme.Metrics.deviceRingWidth)
                    )
            } else if isRegular {
                GeometryReader { proxy in
                    ScrollView {
                        screenBody(pinned: true).frame(minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                    .modifier(PersistentScrollBar(on: scrollBar))
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.xl) { topChrome }
                        .padding(.horizontal, 32)
                        .padding(.top, OnboardingV2Theme.Metrics.screenBodyPaddingTop)
                        .padding(.bottom, Spacing.xl)
                        .background { if dark { OnboardingV2Theme.Palette.darkScreen } else { EPaperBackground() } }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        footer()
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
                    .background { if dark { OnboardingV2Theme.Palette.darkScreen } else { EPaperBackground() } }
                }
            } else {
                // On iPhone the keyboard takes about 40% of the screen, and a
                // step with a field (the kid's name, an email) is taller than
                // what's left: the top went under the status bar and Continue
                // under the keyboard, so there was no way on. The footer is
                // pinned to the bottom edge, which rises with the keyboard, so
                // Continue stays in reach; the rest scrolls above it. At least
                // the visible height, so with the keyboard down the Spacers
                // lay the screen out exactly as before. Back is pinned too:
                // inside a scroll view a button answers late and a slight
                // drag cancels the tap.
                GeometryReader { proxy in
                    ScrollView {
                        screenBody(pinned: true).frame(minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                    .modifier(PersistentScrollBar(on: scrollBar))
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.xl) { topChrome }
                        .padding(.horizontal, OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
                        .padding(.top, OnboardingV2Theme.Metrics.screenBodyPaddingTop)
                        .padding(.bottom, Spacing.xl)
                        .background { if dark { OnboardingV2Theme.Palette.darkScreen } else { EPaperBackground() } }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        footer()
                    }
                    .padding(.horizontal, OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
                    .background { if dark { OnboardingV2Theme.Palette.darkScreen } else { EPaperBackground() } }
                }
            }
        }
        // Shared by every onboarding step (this is the one container all of
        // them render through) — steps with a text field (name entry, code
        // entry, …) relied on a blanket app-wide dismissKeyboardOnTap on
        // RootView, which also sat on top of every other screen in the app
        // including plain NavigationLink rows (Settings' root list) that
        // don't need it and where it measurably delayed tap recognition —
        // wired here instead so it's still covered, just no longer paid for
        // by screens with nothing to dismiss.
        .dismissKeyboardOnTap()
    }
}

extension OnboardingV2ScreenContainer {
    init(embeddedRole role: OnboardingV2Role,
         phase: String,
         stepIndex: Int,
         stepTotal: Int,
         title: String,
         subtitle: String? = nil,
         dark: Bool = false,
         onBack: (() -> Void)? = nil,
         scrollBar: Bool = false,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.init(role: role,
                  phase: phase,
                  stepIndex: stepIndex,
                  stepTotal: stepTotal,
                  title: title,
                  subtitle: subtitle,
                  dark: dark,
                  showsDeviceFrame: false,
                  onBack: onBack,
                  scrollBar: scrollBar,
                  content: content,
                  footer: footer)
    }
}


// MARK: - E-paper page

/// Setup's page and the kid's: plain off-white by day, the blue charcoal at
/// night, no grain (2026-11-14, the user's call: off-white everywhere; a
/// matte warm grey, #F1EFE9, with a fine still grain, the e-paper, from
/// 2026-11-08). The grain is kept below, unused, in case it comes back.
struct EPaperBackground: View {
    var body: some View {
        OnboardingV2Theme.Palette.paper
            .ignoresSafeArea()
    }

    /// 160pt of soft speckle: each pixel a touch lighter or darker.
    static let grain: UIImage = {
        let side = 160
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        var rng = SystemRandomNumberGenerator()
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let c = ctx.cgContext
            for _ in 0..<(side * side / 2) {
                let x = CGFloat(Int.random(in: 0..<(side * 2), using: &rng)) / 2
                let y = CGFloat(Int.random(in: 0..<(side * 2), using: &rng)) / 2
                let dark = Bool.random(using: &rng)
                let a = CGFloat.random(in: 0.02...0.07, using: &rng)
                let ink: UIColor = dark ? UIColor(red: 0.30, green: 0.27, blue: 0.22, alpha: a)
                                        : UIColor(white: 1, alpha: a * 1.4)
                c.setFillColor(ink.cgColor)
                c.fill(CGRect(x: x, y: y, width: 0.5, height: 0.5))
            }
        }
    }()
}

/// A thin scroll bar that stays in view (iOS hides its own when the page is
/// still), so a long step plainly scrolls. On iOS 17 the system's own
/// flashes on appearing instead.
private struct PersistentScrollBar: ViewModifier {
    let on: Bool
    @State private var g = Metrics()
    @Environment(\.horizontalSizeClass) private var hSizeClass

    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var visible: CGFloat = 0
    }

    func body(content: Content) -> some View {
        if !on {
            content
        } else if #available(iOS 18.0, *) {
            content
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Metrics.self) { geo in
                    // The container is already the part between the pinned
                    // header and button; the insets only shift the offset.
                    Metrics(offset: geo.contentOffset.y + geo.contentInsets.top,
                            content: geo.contentSize.height,
                            visible: geo.containerSize.height)
                } action: { _, new in g = new }
                .overlay(alignment: .topTrailing) { bar }
        } else {
            content.scrollIndicatorsFlash(onAppear: true)
        }
    }

    @ViewBuilder private var bar: some View {
        if g.content > g.visible + 1, g.visible > 0 {
            let track = g.visible - 16
            let thumb = max(44, track * g.visible / g.content)
            let travel = max(0, min(1, g.offset / (g.content - g.visible)))
            ZStack(alignment: .top) {
                Capsule().fill(OnboardingV2Theme.Palette.onSurfaceVariant.opacity(0.22))
                Capsule().fill(OnboardingV2Theme.Palette.onSurface.opacity(0.85))
                    .frame(height: thumb)
                    .offset(y: (track - thumb) * travel)
            }
            .frame(width: 6, height: track)
            .padding(.top, 8)
            .padding(.trailing, hSizeClass == .regular ? 10 : 4)
            .allowsHitTesting(false)
        }
    }
}
