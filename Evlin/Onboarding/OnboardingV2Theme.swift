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
        static let surface = Color(hex: "FCFCFD")
        static let surfaceLow = Color(hex: "F7F8FA")
        static let surfaceContainer = Color(hex: "F1F2F4")
        static let surfaceLowest = Color.white

        static let onSurface = Color(hex: "1A1C1E")
        static let onSurfaceVariant = Color(hex: "5A5E66")
        static let outline = Color(hex: "8E9199")
        static let outlineVariant = Color(hex: "E2E4E9")

        // Straight from evlin-style-guide (1).html's :root token block —
        // "everything builds from that one green at different depths."
        static let greenTint = Color(hex: "E4F8E9")   // soft fills, banners, done cards
        static let greenLight = Color(hex: "8CE6A4")  // light accents
        static let greenMascot = Color(hex: "3FCE64") // primary brand — buttons, checks, accents
        static let greenDeep = Color(hex: "25924A")   // button 3D base, deeper accents, status text
        static let greenInk = Color(hex: "0D3318")    // dark green text — swap in when a green fill fails contrast

        static let primary = greenMascot
        static let primaryContainer = Color(hex: "E8F5E9")
        static let onPrimary = Color.white

        // CTA fill — chartreuse, off style-guide-spec by request. Flat (no
        // 3D base), matching ".btn-parent"; text auto-switches to
        // `greenInk` via isLightFill below since this is far lighter than
        // the guide's mascot green.
        static let ctaFill = Color(hex: "58CC02")

        static let secondary = Color(hex: "2E7D32")
        static let secondaryContainer = Color(hex: "E8F5E9")

        static let tertiary = Color(hex: "EF6C00")
        static let tertiaryContainer = Color(hex: "FFF3E0")

        static let error = Color(hex: "D32F2F")
        static let errorContainer = Color(hex: "FFEBEE")

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

        static func titleL(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 26 : 19, weight: .semibold) }
        static let titleLTracking: CGFloat = -0.3

        static func body(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 18 : 13.5, weight: .regular) }
        static let bodyLineSpacing: CGFloat = 13.5 * 0.5

        static func bodyStrong(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 19 : 15, weight: .medium) }
        static let bodyXS = Evlin.Typography.font(11, weight: .regular)
        static func cta(_ regular: Bool) -> Font { Evlin.Typography.font(regular ? 21 : 15, weight: .bold) }
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
        OnboardingV2Theme.Palette.primary
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
    let action: () -> Void

    // Drives disabled dimming from inside the button itself (see body)
    // instead of callers chaining their own `.opacity()` on top — that used
    // to fade the 3D-lift base and the main pill together, and since they're
    // two separate overlapping shapes, the result was a smeared double pill
    // rather than one grayed-out button.
    @Environment(\.isEnabled) private var isEnabled
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
        self.init(title, systemImage: systemImage, fill: role.accent, flat: role == .parent, action: action)
    }

    var body: some View {
        Button(action: action) {
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
            .foregroundStyle(isEnabled ? OnboardingV2Theme.Palette.onPrimary : OnboardingV2Theme.Palette.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, isRegular ? OnboardingV2Theme.Metrics.ctaPaddingVertical + 14 : OnboardingV2Theme.Metrics.ctaPaddingVertical)
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
                            .fill(OnboardingV2Theme.Palette.greenDeep)
                            .offset(y: 5)
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isEnabled ? fill : OnboardingV2Theme.Palette.surfaceContainer)
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
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Secondary / back affordance (`.cta-secondary`)

struct OnboardingV2SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegular: Bool { hSizeClass == .regular }

    init(_ title: String,
         systemImage: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta(isRegular))
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, isRegular ? OnboardingV2Theme.Metrics.ctaPaddingVertical + 14 : OnboardingV2Theme.Metrics.ctaPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: isRegular ? OnboardingV2Theme.Metrics.ctaCornerRadius + 10 : OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isRegular ? OnboardingV2Theme.Metrics.ctaCornerRadius + 10 : OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        self.content = content
        self.footer = footer
    }

    private func backButton() -> some View {
        Button(action: onBack!) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(dark ? Color.white : OnboardingV2Theme.Palette.onSurfaceVariant)
                // Icon reads small on purpose; the frame is the real
                // hit target so it's still comfortable to tap.
                .frame(width: 32, height: 32)
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
    private var screenBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if onBack != nil {
                backButton().padding(.bottom, Spacing.xs)
            }

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

            // On iPhone, flexible Spacers push the footer toward the
            // bottom of the (short) screen — exactly what makes this read
            // as a real iOS screen. On iPad's much taller canvas, those
            // same flexible Spacers absorbed every bit of the extra
            // height instead, stranding the header at the very top and
            // the footer at the very bottom with an empty gap between big
            // enough to lose the actual content in. Fixed spacing plus
            // centering the whole block vertically (below) is what a
            // screen actually designed for the bigger canvas looks like,
            // rather than a phone screen with a hole punched in the
            // middle of it.
            if isRegular {
                // Several steps' own content() closures have their *own*
                // internal flexible Spacers, authored to mimic a real iOS
                // prompt sliding up from the bottom of a phone screen (icon
                // up top, a beat of empty space, the mock system dialog
                // pinned near the bottom). Centering the outer block (below)
                // still proposes this a full screen's worth of height to
                // fill, so those inner Spacers greedily expanded to consume
                // it — recreating the exact same dead-space bug one level
                // deeper. fixedSize forces content() to report its own
                // natural/hugging height instead of accepting that
                // proposal, so its Spacers collapse to their minimum and
                // the icon+card render as one compact group, which is what
                // actually gets centered.
                content()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.section)
                VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                    footer()
                    if let dotsCount, let dotsCurrent {
                        OnboardingV2DotsNav(count: dotsCount, current: dotsCurrent, activeColor: role.accent)
                            .padding(.top, Spacing.sm)
                    }
                }
                .padding(.top, Spacing.section)
            } else {
                Spacer(minLength: Spacing.lg)

                content()

                Spacer(minLength: Spacing.lg)

                VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                    footer()
                    if let dotsCount, let dotsCurrent {
                        OnboardingV2DotsNav(count: dotsCount, current: dotsCurrent, activeColor: role.accent)
                            .padding(.top, Spacing.sm)
                    }
                }
            }
        }
        .padding(.top, OnboardingV2Theme.Metrics.screenBodyPaddingTop)
        .padding(.horizontal, isRegular ? 8 : OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
        .padding(.bottom, OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
        .frame(maxWidth: isRegular ? OnboardingV2Theme.Metrics.iPadCenteredMaxWidth : .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRegular ? .center : .top)
        .background(dark ? OnboardingV2Theme.Palette.darkScreen
                         : OnboardingV2Theme.Palette.surface)
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
            } else {
                screenBody
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
                  content: content,
                  footer: footer)
    }
}
