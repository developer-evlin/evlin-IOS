import PhotosUI
import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

// Shared building blocks used by the v2 onboarding screens, ported from the
// real app's per-file private helpers (Parent/Child V2 step files) and
// consolidated here since this prototype's flow is smaller. Consumes ONLY
// OnboardingV2Theme tokens, matching the source mockup styling.

// MARK: - Field label ("NAME", "BIRTHDAY", …)

extension Text {
    func onboardingV2FieldLabel() -> some View {
        self.font(OnboardingV2Theme.Typography.bodyXS)
            .tracking(0.4)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

// MARK: - Editable `.field` row

struct OnboardingV2EditableField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).onboardingV2FieldLabel()
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(keyboardType == .emailAddress ? .never : .sentences)
                }
            }
            .font(Evlin.Typography.font(16, weight: .semibold))
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            .tint(OnboardingV2Theme.Palette.primary)
            .autocorrectionDisabled()
            .padding(.vertical, OnboardingV2Theme.Metrics.fieldPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.fieldPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
        }
    }
}

/// `.field` chrome wrapping an arbitrary control (e.g. a DatePicker row) so it
/// matches the static field rows visually.
struct OnboardingV2FieldBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.vertical, OnboardingV2Theme.Metrics.fieldPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.fieldPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
    }
}

// MARK: - The big monospaced 6-digit pairing-code entry

struct OnboardingV2CodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("------", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(size: 34, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .tracking(6)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            .tint(OnboardingV2Theme.Palette.primary)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
    }
}

// MARK: - Segmented control ("Female / Male / Other")

// Apple's real segmented control (Settings-style single sliding-thumb bar),
// not a row of standalone pill chips — a chip row reads as "pick any of
// these options" (the same pattern used for colors/categories elsewhere),
// which is the wrong metaphor for a single required choice like this.
// Custom rather than the native `.segmented` Picker style — UIKit fixes that
// control's height at ~32pt (too small a tap target) and, at 4 options
// (age range) instead of 3 (gender), squeezed the highlight thin enough it
// barely showed. Capsule shapes throughout to match the rest of the design
// system (every interactive control here — CTAs, chips, badges — is a true
// capsule, radius = height/2).
//
// Position-driven (an `.offset` computed straight from selectedIndex) rather
// than the earlier Button+matchedGeometryEffect version, and answering to a
// single whole-control DragGesture instead of one Button per segment — that
// combination is what makes a real UISegmentedControl feel light: press
// anywhere and it's instant (no button-press animation delay), and dragging
// a finger across slides the selection the way a native one does, instead of
// only responding to discrete taps.
struct OnboardingV2Segmented: View {
    let options: [String]
    @Binding var selectedIndex: Int

    private let trackHeight: CGFloat = 54
    private let pillInset: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let segmentWidth = geo.size.width / CGFloat(options.count)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .frame(width: max(0, segmentWidth - pillInset * 2), height: trackHeight - pillInset * 2)
                    .offset(x: segmentWidth * CGFloat(selectedIndex) + pillInset)

                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                        Text(label)
                            .font(OnboardingV2Theme.Typography.cta)
                            .foregroundStyle(selectedIndex == i ? OnboardingV2Theme.Palette.onSurface
                                                                 : OnboardingV2Theme.Palette.onSurfaceVariant)
                            .frame(width: segmentWidth, height: trackHeight)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = Int(value.location.x / segmentWidth)
                        let clamped = min(options.count - 1, max(0, idx))
                        if clamped != selectedIndex {
                            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.86)) {
                                selectedIndex = clamped
                            }
                        }
                    }
            )
        }
        .frame(height: trackHeight)
    }
}

// MARK: - Success check (`.check`)

struct OnboardingV2SuccessCheck: View {
    var role: OnboardingV2Role = .parent
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(OnboardingV2Theme.Palette.secondary)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Choice card (role card with emoji tile + title/subtitle)

struct OnboardingV2ChoiceCard: View {
    let emoji: String
    let title: String
    let subtitle: String
    let selected: Bool
    let role: OnboardingV2Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
                    .frame(width: 42, height: 42)
                    .overlay(Text(emoji).font(.system(size: 22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).onboardingV2BodyStrong()
                    Text(subtitle).onboardingV2BodyXS()
                }
                Spacer(minLength: 0)
                if selected {
                    OnboardingV2SuccessCheck(role: role, size: 22)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OnboardingV2Theme.Palette.outline)
                }
            }
            .padding(OnboardingV2Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .stroke(selected ? role.accent : OnboardingV2Theme.Palette.outlineVariant,
                            lineWidth: selected ? 2 : 1)
            )
            .shadow(color: OnboardingV2Theme.Shadow.premiumColor,
                    radius: OnboardingV2Theme.Shadow.premiumRadius,
                    x: 0, y: OnboardingV2Theme.Shadow.premiumY)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waiting spinner + pill

struct OnboardingV2WaitingSpinner: View {
    let name: String
    let subtitle: String

    @State private var spin = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(OnboardingV2Theme.Palette.primary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 46, height: 46)
                .background(
                    Circle().stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 3)
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
            Text("Waiting for \(name)…").onboardingV2BodyStrong()
            Text(subtitle)
                .onboardingV2Body()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
    }
}

struct OnboardingV2WaitingPill: View {
    let title: String
    @State private var spin = false

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(OnboardingV2Theme.Palette.onPrimary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
            Text(title)
        }
        .font(OnboardingV2Theme.Typography.cta)
        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, OnboardingV2Theme.Metrics.ctaPaddingVertical)
        .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                             style: .continuous)
                .fill(OnboardingV2Theme.Palette.primary.opacity(0.82))
        )
    }
}

// MARK: - Numbered step row

struct OnboardingV2NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
            Circle()
                .fill(OnboardingV2Theme.Palette.primary)
                .frame(width: 26, height: 26)
                .overlay(
                    Text("\(number)")
                        .font(Evlin.Typography.font(13, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                )
                .fixedSize()
            Text(text)
                .onboardingV2BodyStrong()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chat bubble

struct OnboardingV2ChatBubble: View {
    enum Speaker { case me, evlin }

    let speaker: Speaker
    private let plain: String?
    private let rich: AttributedString?

    init(_ speaker: Speaker, text: String) {
        self.speaker = speaker
        self.plain = text
        self.rich = nil
    }

    init(_ speaker: Speaker, attributed: AttributedString) {
        self.speaker = speaker
        self.plain = nil
        self.rich = attributed
    }

    private var isMe: Bool { speaker == .me }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 40) }
            Group {
                if let rich { Text(rich) } else { Text(plain ?? "") }
            }
            .font(OnboardingV2Theme.Typography.body)
            .foregroundStyle(isMe ? OnboardingV2Theme.Palette.onPrimary
                                  : OnboardingV2Theme.Palette.onSurface)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isMe ? OnboardingV2Theme.Palette.primary
                               : OnboardingV2Theme.Palette.surfaceContainer)
            )
            if !isMe { Spacer(minLength: 40) }
        }
    }
}

// MARK: - App icon tile + badge chip

struct OnboardingV2AppIcon: View {
    let letter: String
    let fill: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .frame(width: 38, height: 38)
            .overlay(
                Text(letter)
                    .font(Evlin.Typography.font(17, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

struct OnboardingV2Badge: View {
    enum Style { case success, warn, new }

    let text: String
    let style: Style

    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    private var fg: Color {
        switch style {
        case .success: return OnboardingV2Theme.Palette.secondary
        case .warn:    return Color(hex: "856404")
        case .new:     return Color(hex: "1B53B3")
        }
    }
    private var bg: Color {
        switch style {
        case .success: return OnboardingV2Theme.Palette.secondaryContainer
        case .warn:    return Color(hex: "FFF3CD")
        case .new:     return Color(hex: "E7F0FF")
        }
    }

    var body: some View {
        Text(text)
            .font(Evlin.Typography.font(10, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(fg)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(bg))
    }
}

// MARK: - Faux QR (decorative — used while a real code hasn't "minted" yet,
// and as the parent's non-functional "camera preview" placeholder — this
// prototype never drives a real camera or scanner).

struct OnboardingV2FauxQR: View {
    var size: CGFloat = 150
    private let n = 21

    private func isFinder(_ x: Int, _ y: Int) -> Bool {
        func inFinder(_ ox: Int, _ oy: Int) -> Bool {
            let lx = x - ox, ly = y - oy
            guard (0...6).contains(lx), (0...6).contains(ly) else { return false }
            let ring = lx == 0 || lx == 6 || ly == 0 || ly == 6
            let core = (2...4).contains(lx) && (2...4).contains(ly)
            return ring || core
        }
        return inFinder(0, 0) || inFinder(0, n - 7) || inFinder(n - 7, 0)
    }

    private func inFinderZone(_ x: Int, _ y: Int) -> Bool {
        (x < 8 && y < 8) || (x < 8 && y >= n - 8) || (x >= n - 8 && y < 8)
    }

    private func isData(_ x: Int, _ y: Int) -> Bool {
        guard !inFinderZone(x, y) else { return false }
        return ((x * x + y * 3 + x * y) % 5) < 2
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let cell = canvasSize.width / CGFloat(n)
            for y in 0..<n {
                for x in 0..<n {
                    let on = isFinder(x, y) || isData(x, y)
                    guard on else { continue }
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                      width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(OnboardingV2Theme.Palette.primary))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// A moving line sweeping the faux QR, selling the "camera preview" as
// actively looking for a code instead of a static frozen graphic — shared
// by both pairing screens the app has (this onboarding step and Settings'
// Add Child flow), so a fix/tweak here doesn't need repeating twice.
struct OnboardingV2ScanLine: View {
    var size: CGFloat = 200
    @State private var atBottom = false

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.clear, Color(hex: "3FCE64"), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: size, height: 3)
            .shadow(color: Color(hex: "3FCE64").opacity(0.8), radius: 6)
            .offset(y: atBottom ? size / 2 - 4 : -(size / 2 - 4))
            .task {
                // A repeatForever animation kicked off directly in
                // .onAppear races with SwiftUI's own transaction for the
                // view's initial appearance — it usually wins, but when it
                // loses, the animation never actually starts and the line
                // sticks at its starting position. .task always runs in
                // its own transaction after appear, sidestepping the race.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    atBottom = true
                }
            }
    }
}

// MARK: - Real, scannable QR (kid's pairing code) — pure CoreImage, no camera
// / photo-library permission needed.

enum OnboardingV2PairPayload {
    static func encode(code: String) -> String { "evlin-pair:\(code)" }
}

struct OnboardingV2QRImage: View {
    let string: String
    var side: CGFloat = 208

    var body: some View {
        Group {
            if let img = Self.makeQR(from: string) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: side, height: side)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func makeQR(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Photo avatar picker (library only — no camera capture, so no new
// Info.plist usage-description strings are needed for this prototype).

struct OnboardingV2InitialsAvatar: View {
    let name: String
    var size: CGFloat = 66
    var accent: Color = OnboardingV2Theme.Palette.primary

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?").uppercased()
    }

    var body: some View {
        Circle()
            .fill(accent.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(Evlin.Typography.font(size * 0.4, weight: .bold))
                    .foregroundStyle(accent)
            )
    }
}

struct OnboardingV2PhotoAvatarPicker: View {
    let name: String
    @Binding var pickedImage: UIImage?
    var size: CGFloat = 66
    var accent: Color = OnboardingV2Theme.Palette.primary

    @State private var showDialog = false
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        Button { showDialog = true } label: {
            ZStack(alignment: .bottomTrailing) {
                if let pickedImage {
                    Image(uiImage: pickedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    OnboardingV2InitialsAvatar(name: name, size: size, accent: accent)
                }
                Image(systemName: "plus")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(accent))
                    .overlay(Circle().stroke(OnboardingV2Theme.Palette.surface, lineWidth: 2))
            }
        }
        .buttonStyle(.plain)
        .photosPicker(isPresented: $showDialog, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { pickedImage = img }
                }
            }
        }
    }
}
