import SwiftUI

// MARK: - How to set up Family Sharing, shown on the kid's iPad
//
// 2026-11-09, the user's sequence: the iPad shows the parent what to do on
// their iPhone (create the child's Apple Account in Family Sharing), then
// what to do back on the iPad (sign it in with that account). An iPhone
// step on the parent's own phone right after pairing was built first and
// taken out the same day for this.
//
// The animation is drawn here, not a screen recording (and not anyone
// else's video): a light device in iOS's own look (a picture of Settings,
// so it stays light on the warm night page), going through the steps with a
// tap mark on what to press and a numbered caption under it. It loops;
// Reduce Motion holds each step without the tap mark moving.

/// The how-to for one device: the iPhone part or the iPad part. It plays by
/// itself, slowly (about five seconds a step), and the parent can swipe
/// through it or tap a dot; after a swipe it waits longer before moving on
/// (2026-11-09, the user's ask: slower, scrollable, the information
/// highlighted). What to press glows with a breathing ring before it's
/// pressed, and the caption's key words are green.
struct FamilySharingHowTo: View {
    /// `.both` plays the whole thing in one: the iPhone's steps, then the
    /// iPad's (2026-11-10, the user's ask for the iPhone's instructions).
    enum Part { case iPhone, iPad, both }
    let part: Part
    let kidName: String

    /// How many steps a part has.
    static func count(_ part: Part) -> Int {
        switch part {
        case .iPhone: return phoneSteps
        case .iPad: return 3
        case .both: return phoneSteps + 3
        }
    }

    @State private var scene = 0
    /// The press: the ring breathes on what to press, then presses it.
    @State private var tap = false
    /// When the parent last swiped or tapped a dot.
    @State private var touchedAt: Date?
    /// Set while the timer turns the page, to tell it from a swipe.
    @State private var autoTurning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Each step's words, its key words in **bold** (drawn green).
    private var captions: [String] {
        // Settings, your name, Family, Add Member, Create Child Account
        // (2026-11-10, the user's order: through the parent's own profile).
        let phone = [
            "On **your iPhone**, open **Settings** and tap **Apple Account** at the top.",
            "Tap **Family**",
            "Tap **Add Member** at the top",
            "Tap **Create Child Account**",
            "Follow Apple's steps to make **\(kidName)'s account**",
            // Parental controls: keep Apple's content limits (2026-11-11,
            // the user's call). Its time limits aren't mentioned: Evlin sets
            // the time (2026-11-12; a "tap Not Now" step before).
            "Keep **Ask to Buy** and the **content limits** on",
            // Lock Apple's Screen Time settings with a passcode (2026-11-11,
            // the user's ask), so the child can't change them.
            "Tap **Manage Screen Time** → **Lock Screen Time Settings**",
        ]
        switch part {
        case .iPhone: return phone
        case .iPad:
            return [
                // Apple's own way to sign a child in (2026-11-12, the user's
                // call, from Apple's guide): Sign In Manually, then "Sign in a
                // child in my Family". "Sign in with Mia's new Apple Account"
                // before was unclear to parents.
                // Someone already signed in: out first, in step 1; step 3 is
                // the button under Continue, as the iPad shows it (2026-11-12,
                // the user's screenshot). Its note says to come back to Evlin
                // in place of ", under Continue" (2026-11-14, the user's call).
                "On **\(kidName)'s device**, open **Settings** and tap **Sign in**\nAlready signed in? Tap the name, then Sign Out.",
                "Tap **Sign In Manually**",
                "Tap **Sign in a Child in My Family**\nOnce signed in, **come back to Evlin**.",
            ]
        case .both:
            return phone + [
                "On \(kidName)'s iPad, open **Settings** and tap **Sign in**\nAlready signed in? Tap the name, then Sign Out.",
                "Tap **Sign In Manually**",
                "Tap **Sign in a Child in My Family**, under Continue",
            ]
        }
    }

    /// Which device step `i` is drawn on.
    private func device(_ i: Int) -> Part {
        switch part {
        case .both: return i < Self.phoneSteps ? .iPhone : .iPad
        default: return part
        }
    }

    /// How many steps the iPhone part has.
    private static let phoneSteps = 7

    private static func base(_ d: Part) -> CGSize {
        d == .iPad ? CGSize(width: 250, height: 320) : CGSize(width: 180, height: 340)
    }

    var body: some View {
        let big = hSizeClass == .regular
        // Drawn at one size and scaled up whole, so the screens keep their
        // proportions: much bigger on the iPad (2026-11-09, the user's ask).
        // The tallest device shown sets the pages' height.
        let tallest = (0..<captions.count).map { size(device($0), big: big).height }.max() ?? 340
        VStack(spacing: 14) {
            TabView(selection: $scene) {
                ForEach(0..<captions.count, id: \.self) { i in
                    page(i, big: big).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: tallest + (big ? 100 : 96) + (part == .both ? 30 : 0))
            // Round arrows either side of the drawing, as a photo carousel
            // has (2026-11-11, the user's call: "Swipe through them" meant
            // nothing to people, and a Next pill by the dots with "Tap Next
            // for each one" looked messy). Swiping still works.
            .overlay(alignment: .top) {
                let w = size(device(scene), big: big).width
                HStack(spacing: w + (big ? 36 : 22)) {
                    arrow(back: true).opacity(scene == 0 ? 0 : 1).disabled(scene == 0)
                    arrow(back: false).opacity(scene == captions.count - 1 ? 0 : 1)
                        .disabled(scene == captions.count - 1)
                }
                .padding(.top, 4 + tallest / 2 - (big ? 26 : 21))
                .animation(.smooth(duration: 0.25), value: scene)
            }
            .onChange(of: scene) { _, _ in
                if !autoTurning { touchedAt = Date() }
                tap = false
            }

            HStack(spacing: 8) {
                ForEach(0..<captions.count, id: \.self) { i in
                    Button {
                        turnTo(i)
                    } label: {
                        Capsule()
                            .fill(i == scene ? OnboardingV2Theme.Palette.secondary : OnboardingV2Theme.Palette.outlineVariant)
                            .frame(width: i == scene ? 22 : 8, height: 8)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Step \(i + 1)")
                }
            }
        }
        .task(id: scene) { await dwell() }
    }

    /// The drawn device's size on screen: drawn at one size and scaled up
    /// whole, so the screens keep their proportions; much bigger on the
    /// iPad (2026-11-09, the user's ask).
    private func size(_ d: Part, big: Bool) -> CGSize {
        let b = Self.base(d)
        // A little smaller on a phone in the whole walkthrough, to leave
        // room for its device label and the dots above Done.
        // On a phone the iPad drawing is a little smaller, to leave room for
        // the words over it and its caption above the button.
        let k: CGFloat = big ? (d == .iPad ? 1.55 : 1.72) : (part == .both ? 0.88 : (d == .iPad ? 0.84 : 1.0))
        return CGSize(width: b.width * k, height: b.height * k)
    }

    private func page(_ i: Int, big: Bool) -> some View {
        let d = device(i)
        let base = Self.base(d)
        let device = size(d, big: big)
        return VStack(spacing: 16) {
            // In the whole walkthrough, which device this step happens on.
            if part == .both {
                Label(d == .iPhone ? "On your iPhone" : "On \(kidName)'s iPad",
                      systemImage: d == .iPhone ? "iphone.gen3" : "ipad")
                    .font(Typography.font(big ? 14 : 12.5, weight: .semibold))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    .frame(height: 14)
            }
            Group {
                if d == .iPhone {
                    HowToPhone { screen(i) }
                } else {
                    HowToTablet { screen(i) }
                }
            }
            .frame(width: base.width, height: base.height)
            .scaleEffect(device.width / base.width)
            .frame(width: device.width, height: device.height)
            // Not sure? The parent can tap the drawing themselves: it
            // presses what's highlighted and goes on to the next step
            // (2026-11-10, the user's ask).
            .contentShape(Rectangle())
            .onTapGesture { pressByHand(i) }

            // A floating card that stands off the page, like a checklist
            // item (2026-11-11: the flat pill blended into the page).
            HStack(alignment: .center, spacing: 12) {
                Text("\(i + 1)")
                    .font(Typography.font(big ? 17 : 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: big ? 34 : 29, height: big ? 34 : 29)
                    .background(Circle().fill(OnboardingV2Theme.Palette.secondary))
                Text(styled(captions[i], big: big))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, big ? 22 : 18)
            .padding(.vertical, big ? 16 : 14)
            .background(Self.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(i + 1): " + captions[i].replacingOccurrences(of: "**", with: ""))
    }

    static let cardFill = Color(light: "FBFAF6", dark: "2C3037", warm: "2C3037")
    static let cardEdge = Color(light: "E5E5EA", dark: "3D424B", warm: "3D424B")

    /// The caption: semibold in the page's ink, its key words green.
    private func styled(_ line: String, big: Bool) -> AttributedString {
        var a = (try? AttributedString(markdown: line)) ?? AttributedString(line)
        a.font = Typography.font(big ? 22 : 17.5, weight: .semibold)
        a.foregroundColor = OnboardingV2Theme.Palette.onSurface
        for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].foregroundColor = OnboardingV2Theme.Palette.secondary
            a[run.range].font = Typography.font(big ? 22 : 17.5, weight: .bold)
        }
        return a
    }

    @ViewBuilder private func screen(_ i: Int) -> some View {
        // Step within its device: the iPad's steps start at 4 in `.both`.
        let j = part == .both && i >= Self.phoneSteps ? i - Self.phoneSteps : i
        Self.drawn(device(i), j, kidName: kidName, tap: tap && i == scene)
    }

    /// Step `j` of a device's part, drawn.
    @ViewBuilder fileprivate static func drawn(_ d: Part, _ j: Int, kidName: String, tap pressed: Bool) -> some View {
        switch (d, j) {
        case (.iPhone, 0): SettingsScreen(tap: pressed)
        case (.iPhone, 1): AccountScreen(tap: pressed)
        case (.iPhone, 2): FamilyScreen(tap: pressed)
        case (.iPhone, 3): AddMemberScreen(tap: pressed)
        case (.iPhone, 4): ChildAccountScreen(kidName: kidName, tap: pressed)
        case (.iPhone, 5): ContentLimitsScreen(tap: pressed)
        case (.iPhone, _): LockScreenTimeScreen(tap: pressed)
        case (_, 0): TabletSettingsScreen(tap: pressed)
        case (_, 1): TabletSignInManuallyScreen(tap: pressed)
        case (_, _): TabletSignInChildScreen(kidName: kidName, tap: pressed)
        }
    }

    /// Every step's words, for the scrolling list.
    fileprivate static func captions(_ part: Part, kidName: String) -> [String] {
        FamilySharingHowTo(part: part, kidName: kidName).captions
    }

    /// The caption, for the scrolling list.
    fileprivate static func styledCaption(_ line: String, big: Bool) -> AttributedString {
        FamilySharingHowTo(part: .iPhone, kidName: "").styled(line, big: big)
    }

    private func turnTo(_ i: Int) {
        touchedAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.35)) { scene = i }
    }

    private func arrow(back: Bool) -> some View {
        let big = hSizeClass == .regular
        let d: CGFloat = big ? 52 : 42
        return Button {
            turnTo(back ? max(scene - 1, 0) : min(scene + 1, captions.count - 1))
        } label: {
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: big ? 20 : 16, weight: .semibold))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                .frame(width: d, height: d)
                .background(Circle().fill(OnboardingV2Theme.Palette.surfaceLowest))
                .overlay(Circle().strokeBorder(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(back ? "Previous step" : "Next step")
    }

    /// The parent tapped the drawing: press now, then the next step.
    private func pressByHand(_ i: Int) {
        guard i == scene else { return }
        touchedAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) { tap = true }
        let next = (scene + 1) % captions.count
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard scene == i else { return }
            withAnimation(.smooth(duration: 0.5)) { scene = next }
        }
    }

    /// On a step: the ring breathes on what to press, it's pressed, and
    /// after a while the next step slides in. Longer after a swipe, so the
    /// parent's own pace wins.
    private func dwell() async {
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2)) { tap = true }
        // Once the parent has turned a page themselves, the pages stay
        // where they put them (2026-11-11, with the Next button).
        guard touchedAt == nil else { return }
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        guard !Task.isCancelled, touchedAt == nil else { return }
        autoTurning = true
        withAnimation(.smooth(duration: 0.6)) { scene = (scene + 1) % captions.count }
        DispatchQueue.main.async { autoTurning = false }
    }
}

// MARK: - The iPhone's steps as one scrolling list

/// How the parent makes the child's account on their iPhone, every step
/// down one page to scroll (2026-11-12, the user's call: a carousel turned
/// by "Done, next step" and Back made no sense). Each step is its number
/// and words beside its drawing on the iPad, the words over it on a phone;
/// each drawing presses what's highlighted, again and again.
struct FamilySharingStepList: View {
    let kidName: String
    /// Whose steps: the iPhone's (making the account, on the child's
    /// device) or the iPad's (signing it in, on the parent's phone).
    var part: FamilySharingHowTo.Part = .iPhone
    /// Shown on the device the steps are for: the first step says just what
    /// to tap, not which device (the iPad's own sign-in page, 2026-11-12).
    var onThatDevice = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var captions: [String] {
        var c = FamilySharingHowTo.captions(part, kidName: kidName)
        if onThatDevice, part == .iPad, !c.isEmpty {
            c[0] = "Open **Settings** and tap **Sign in**\nAlready signed in? Tap the name, then Sign Out."
        }
        // The account steps end by saying to come back, its words in green
        // (2026-11-13, the user's call).
        if part == .iPhone, !c.isEmpty {
            c[c.count - 1] += "\nWhen you're done, **come back to Evlin**."
        }
        return c
    }

    var body: some View {
        let big = hSizeClass == .regular
        LazyVStack(spacing: big ? 28 : (part == .iPad ? 14 : 22)) {
            ForEach(captions.indices, id: \.self) { i in
                FamilySharingStepRow(index: i, caption: captions[i], kidName: kidName, part: part, big: big)
            }
        }
        .frame(maxWidth: big ? 760 : 520)
        .padding(.horizontal, big ? 0 : 4)
    }
}

private struct FamilySharingStepRow: View {
    let index: Int
    let caption: String
    let kidName: String
    /// The device drawn beside the words.
    let part: FamilySharingHowTo.Part
    let big: Bool
    @State private var tap = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var base: CGSize {
        part == .iPad ? CGSize(width: 250, height: 320) : CGSize(width: 180, height: 340)
    }

    @ViewBuilder private var drawing: some View {
        // On a phone the iPad's steps sit beside their words, small, so
        // both fit on the page (2026-11-12, the user's ask).
        let k: CGFloat = big ? 1.12 : (part == .iPad ? 0.5 : 0.82)
        Group {
            if part == .iPad {
                HowToTablet { FamilySharingHowTo.drawn(.iPad, index, kidName: kidName, tap: tap) }
            } else {
                HowToPhone { FamilySharingHowTo.drawn(.iPhone, index, kidName: kidName, tap: tap) }
            }
        }
        .frame(width: base.width, height: base.height)
        .scaleEffect(k)
        .frame(width: base.width * k, height: base.height * k)
    }

    var body: some View {
        Group {
            if big || part == .iPad {
                HStack(alignment: .center, spacing: big ? 36 : 14) {
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    drawing
                }
                .padding(.horizontal, big ? 32 : 16)
                .padding(.vertical, big ? 26 : 12)
            } else {
                VStack(spacing: 18) {
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    drawing
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
        }
        .background(FamilySharingHowTo.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(FamilySharingHowTo.cardEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1): " + caption.replacingOccurrences(of: "**", with: ""))
        // Only while it's on screen (the list is lazy): the ring breathes
        // on what to press, then presses it.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2)) { tap = true }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.4)) { tap = false }
            }
        }
    }

    /// On a phone, the parent's steps put the number beside the words, so
    /// all of them fit on the page.
    private var inline: Bool { !big && part != .iPhone }

    @ViewBuilder private var words: some View {
        let layout = inline
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: big ? 16 : 12))
        layout {
            Text("\(index + 1)")
                .font(Typography.font(big ? 19 : (inline ? 14 : 16), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: big ? 40 : (inline ? 28 : 32), height: big ? 40 : (inline ? 28 : 32))
                .background(Circle().fill(OnboardingV2Theme.Palette.secondary))
            // A caption's second line is a quiet note under it, smaller and
            // grey (2026-11-12: the sign-out case in step 1 cluttered it).
            let parts = caption.components(separatedBy: "\n")
            VStack(alignment: .leading, spacing: big ? 8 : 6) {
                Text(FamilySharingHowTo.styledCaption(parts[0], big: big))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if parts.count > 1 {
                    Text(note(parts[1]))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension FamilySharingStepRow {
    /// The quiet note: grey, its **bold** words green (come back to Evlin).
    fileprivate func note(_ line: String) -> AttributedString {
        let size: CGFloat = big ? 17 : 14.5
        var a = (try? AttributedString(markdown: line)) ?? AttributedString(line)
        a.font = Typography.font(size, weight: .medium)
        a.foregroundColor = OnboardingV2Theme.Palette.onSurfaceVariant
        for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].foregroundColor = OnboardingV2Theme.Palette.secondary
            a[run.range].font = Typography.font(size, weight: .bold)
        }
        return a
    }
}

// MARK: - The drawn phone and its screens

private enum Mock {
    static let page = Color(hex: "F2F2F7")
    static let card = Color.white
    static let ink = Color(hex: "1C1C1E")
    static let soft = Color(hex: "8E8E93")
    static let line = Color(hex: "E5E5EA")
    static let blue = Color(hex: "0A84FF")
    static let green = Color(hex: "34C759")
}

private struct HowToPhone<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Mock.page)
                .padding(7)
            content()
                .padding(.top, 34)
                .padding(.horizontal, 7)
                .padding(.bottom, 7)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous).inset(by: 7))
            Capsule().fill(Color(hex: "1C1C1E"))
                .frame(width: 62, height: 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// A Settings-style row: icon tile, title, chevron. `hot` gets the tap mark.
private struct MockRow: View {
    var icon: String
    var tint: Color
    var title: String
    var hot = false
    var tap = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Mock.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Mock.soft.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(hot ? Mock.blue.opacity(tap ? 0.16 : 0.07) : .clear)
        .overlay { if hot { RoundedRectangle(cornerRadius: 8).strokeBorder(Mock.blue, lineWidth: 1.5) } }
        .overlay(alignment: .trailing) { if hot { TapMark(on: tap).padding(.trailing, 24) } }
    }
}

/// The finger: a soft ring that lands and presses.
/// The finger: a ring breathing on what to press, so the eye goes there
/// first, then it presses (shrinks and fills).
private struct TapMark: View {
    var on: Bool
    @State private var breathe = false
    var body: some View {
        Circle()
            .fill(Mock.blue.opacity(on ? 0.4 : 0.12))
            .overlay(Circle().strokeBorder(Mock.blue, lineWidth: 2.5))
            .frame(width: 30, height: 30)
            .scaleEffect(on ? 0.75 : (breathe ? 1.25 : 1.0))
            .shadow(color: Mock.blue.opacity(0.5), radius: on ? 2 : 8)
            // A hand whose fingertip rests on the ring and taps it
            // (2026-11-11), so it's plain where the finger goes.
            .overlay {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1.5)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .offset(x: on ? 10 : 14, y: on ? 13 : 18)
                    .scaleEffect(on ? 0.92 : 1)
                    .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

private struct MockHeader: View {
    var title: String
    var back: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let back {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(back).font(.system(size: 11))
                }
                .foregroundStyle(Mock.blue)
            }
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Mock.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct MockGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Mock.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
    }
}

private struct SettingsScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            MockHeader(title: "Settings")
            MockGroup {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "C7C7CC")).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Mock.ink).lineLimit(1)
                        Text("Apple Account").font(.system(size: 8.5)).foregroundStyle(Mock.soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .padding(.trailing, 14)
                .background(Mock.blue.opacity(tap ? 0.16 : 0.07))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Mock.blue, lineWidth: 1.5) }
                .overlay(alignment: .trailing) { TapMark(on: tap).padding(.trailing, 6) }
            }
            MockGroup {
                MockRow(icon: "airplane", tint: Color(hex: "FF9500"), title: "Airplane Mode")
                MockRow(icon: "wifi", tint: Mock.blue, title: "Wi-Fi")
                MockRow(icon: "hourglass", tint: Color(hex: "5E5CE6"), title: "Screen Time")
            }
            Spacer(minLength: 0)
        }
    }
}

/// The parent's Apple Account page, opened from their name, with Family.
private struct AccountScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 8) {
            MockHeader(title: "Apple Account", back: "Settings")
            VStack(spacing: 3) {
                Circle().fill(Color(hex: "C7C7CC")).frame(width: 36, height: 36)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 17)).foregroundStyle(.white))
                Text("Your Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Mock.ink)
            }
            MockGroup {
                MockRow(icon: "key.fill", tint: Color(hex: "8E8E93"), title: "Sign-In & Security")
            }
            MockGroup {
                MockRow(icon: "icloud.fill", tint: Mock.blue, title: "iCloud")
                MockRow(icon: "figure.2.and.child.holdinghands", tint: Mock.blue, title: "Family", hot: true, tap: tap)
                MockRow(icon: "location.fill", tint: Mock.green, title: "Find My")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FamilyScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Mock.blue)
                    .overlay { TapMark(on: tap) }
                    .padding(.trailing, 14)
            }
            MockHeader(title: "Family", back: "Apple Account")
            Image(systemName: "figure.2.and.child.holdinghands")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Mock.blue)
                .frame(width: 58, height: 58)
                .background(Mock.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Add Member")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mock.blue)
            MockGroup {
                MockRow(icon: "person.fill", tint: Color(hex: "C7C7CC"), title: "You (Organizer)")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AddMemberScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 12) {
            MockHeader(title: "Add Member", back: "Family")
            Spacer().frame(height: 6)
            button("Invite Others", filled: false, hot: false)
            button("Create Child Account", filled: true, hot: true)
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, filled: Bool, hot: Bool) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(filled ? .white : Mock.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(filled ? Mock.blue : Mock.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(hot && tap ? 0.7 : 1)
            .overlay { if hot { TapMark(on: tap) } }
            .padding(.horizontal, 14)
    }
}

/// Apple's child-account form, filled in, with Continue pressed.
private struct ChildAccountScreen: View {
    var kidName: String
    var tap: Bool
    private var name: String { kidName.prefix(1).uppercased() + kidName.dropFirst() }
    var body: some View {
        VStack(spacing: 10) {
            MockHeader(title: "Child Account", back: "Add Member")
            MockGroup {
                field("Name", name)
                Rectangle().fill(Mock.line).frame(height: 0.5).padding(.leading, 10)
                field("Birthday", "June 4, 2017")
                Rectangle().fill(Mock.line).frame(height: 0.5).padding(.leading, 10)
                field("Apple Account", "\(name.lowercased().filter { $0.isLetter })@icloud.com")
            }
            Text("Continue")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Mock.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(tap ? 0.7 : 1)
                .overlay(alignment: .trailing) { TapMark(on: tap).padding(.trailing, 18) }
                .padding(.horizontal, 14)
            Spacer(minLength: 0)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 9.5)).foregroundStyle(Mock.soft)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 10.5)).foregroundStyle(Mock.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// Apple's parental controls for the new account: Ask to Buy and the
/// content limits stay on, Continue.
private struct ContentLimitsScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            MockHeader(title: "Parental Controls")
            MockGroup {
                toggle("cart.fill", Color(hex: "34C759"), "Ask to Buy")
                Rectangle().fill(Mock.line).frame(height: 0.5).padding(.leading, 36)
                toggle("hand.raised.fill", Color(hex: "FF3B30"), "Content Limits")
            }
            Text("Continue")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Mock.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(tap ? 0.7 : 1)
                .overlay(alignment: .trailing) { TapMark(on: tap).padding(.trailing, 18) }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ icon: String, _ tint: Color, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Mock.ink)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            Capsule().fill(Mock.green)
                .frame(width: 26, height: 16)
                .overlay(alignment: .trailing) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(.trailing, 1.5)
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// Manage Screen Time for the child, with Lock Screen Time Settings
/// switched on as it's pressed.
private struct LockScreenTimeScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            MockHeader(title: "Screen Time", back: "Parental Controls")
            MockGroup {
                MockRow(icon: "moon.zzz.fill", tint: Color(hex: "5E5CE6"), title: "Downtime")
                MockRow(icon: "hourglass", tint: Color(hex: "FF9500"), title: "App Limits")
                MockRow(icon: "hand.raised.fill", tint: Color(hex: "FF3B30"), title: "Content Limits")
            }
            MockGroup {
                HStack(spacing: 8) {
                    Text("Lock Screen Time Settings")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Mock.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    Capsule().fill(tap ? Mock.green : Color(hex: "E5E5EA"))
                        .frame(width: 26, height: 16)
                        .overlay(alignment: tap ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: 13, height: 13).padding(.horizontal, 1.5)
                        }
                        .overlay { TapMark(on: tap) }
                        .animation(.smooth(duration: 0.25), value: tap)
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 40)
                .background(Mock.blue.opacity(tap ? 0.16 : 0.07))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Mock.blue, lineWidth: 1.5) }
            }
            Text("Use a passcode so only you can change these settings.")
                .font(.system(size: 8.5))
                .foregroundStyle(Mock.soft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
    }
}

/// A drawn iPad: an even bezel all round, no notch.
private struct HowToTablet<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Mock.page)
                .padding(10)
            content()
                .padding(.top, 22)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous).inset(by: 10))
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// iPad Settings before anyone's signed in: "Sign in to your iPad" on top.
private struct TabletSettingsScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            MockHeader(title: "Settings")
            MockGroup {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "C7C7CC")).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in to your iPad").font(.system(size: 12, weight: .semibold)).foregroundStyle(Mock.blue)
                        Text("iCloud, the App Store and more").font(.system(size: 8.5)).foregroundStyle(Mock.soft)
                    }
                    Spacer(minLength: 30)
                }
                .padding(10)
                .background(tap ? Mock.line : .clear)
                .overlay(alignment: .trailing) { TapMark(on: tap).padding(.trailing, 8) }
            }
            MockGroup {
                MockRow(icon: "airplane", tint: Color(hex: "FF9500"), title: "Airplane Mode")
                MockRow(icon: "wifi", tint: Mock.blue, title: "Wi-Fi")
                MockRow(icon: "hourglass", tint: Color(hex: "5E5CE6"), title: "Screen Time")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Apple's sign-in page: Use Another Apple Device, and Sign In Manually
/// pressed.
private struct TabletSignInManuallyScreen: View {
    var tap: Bool
    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 14)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(hex: "C7C7CC"))
            Text("Apple Account")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Mock.ink)
            Spacer().frame(height: 4)
            Text("Use Another Apple Device")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mock.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Mock.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 22)
            Text("Sign In Manually")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Mock.blue, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(tap ? 0.7 : 1)
                .overlay(alignment: .trailing) { TapMark(on: tap).padding(.trailing, 14) }
                .padding(.horizontal, 22)
            Spacer(minLength: 0)
        }
    }
}

/// Signing in manually, as the iPad shows it: the email field, a grey
/// Continue, and under it "Sign in a Child in My Family", pressed.
private struct TabletSignInChildScreen: View {
    var kidName: String
    var tap: Bool
    var body: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 10)
            Text("Apple Account")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Mock.ink)
            HStack {
                Text("Email or Phone Number").font(.system(size: 10.5)).foregroundStyle(Mock.soft)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Mock.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 22)
            VStack(spacing: 3) {
                Capsule().fill(Mock.line).frame(height: 4)
                Capsule().fill(Mock.line).frame(width: 110, height: 4)
            }
            .padding(.horizontal, 30)
            Text("Continue")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Mock.soft)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Mock.line, in: Capsule())
                .padding(.horizontal, 22)
            Text("Sign in a Child in My Family")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mock.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Mock.blue.opacity(tap ? 0.16 : 0.07), in: Capsule())
                .overlay { Capsule().strokeBorder(Mock.blue, lineWidth: 1.5) }
                .overlay(alignment: .trailing) { TapMark(on: tap).offset(x: 10) }
            Spacer(minLength: 0)
        }
    }
}
