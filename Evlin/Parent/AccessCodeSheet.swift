import SwiftUI

/// The screen time access code, on the parent's phone (2026-11-19). Opened
/// from Settings' "Screen time access code" row (on Profile before, the same
/// day: parents won't use it much), only after Face ID, Touch ID or the
/// phone's passcode (`ParentIdentity`). The parent types it on any of their
/// children's devices to get into its settings. Made by the server
/// (`AccessCode`), good for a minute and once; a pie counts down, and a new
/// one is fetched when it runs out. Closed by itself when the phone leaves
/// Evlin, so a code isn't left on show.
/// A pop-up card in the middle of the dimmed screen (2026-11-19, the user's
/// call; a half sheet before); a tap outside it or the x closes it.
struct AccessCodeSheet: View {
    var onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var shown = false
    @State private var current: AccessCode.Current?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }
            if shown {
                card
                    .padding(.horizontal, 24)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .onAppear { withAnimation(.snappy(duration: 0.28)) { shown = true } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { onClose() }
        }
        // The code, and a new one each time it runs out.
        .task(id: attempt) {
            while !Task.isCancelled {
                do {
                    let next = try await AccessCode.fetch()
                    failed = false
                    current = next
                    let wait = max(1, next.expires.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(wait))
                } catch {
                    if current == nil || (current?.expires ?? .distantPast) < Date() { failed = true; current = nil }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SheetCloseButton(action: close)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Text("Screen time access code")
                .font(Typography.font(22, weight: .semibold))
                .foregroundStyle(Neutral.ink)
                .padding(.top, 4)

            // Smooth, so the pie empties evenly rather than in steps.
            TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                let now = timeline.date
                Group {
                    if let current, current.expires > now {
                        let left = current.fractionLeft(at: now)
                        // The last 10 seconds: red, as authenticator apps
                        // warn a code is about to change.
                        let ending = current.expires.timeIntervalSince(now) <= 10
                        HStack(spacing: 16) {
                            Text(grouped(current.code))
                                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                                .tracking(4)
                                .foregroundStyle(ending ? EColor.danger : Neutral.ink)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: current.code)
                                .animation(.easeInOut(duration: 0.3), value: ending)
                                .accessibilityLabel(current.code.map(String.init).joined(separator: " "))
                            // How long the code has left, with no numbers:
                            // a pie that empties as the minute runs out.
                            CodeTimer(left: left, color: ending ? EColor.danger : FormGreen.accent)
                                .frame(width: 26, height: 26)
                                .animation(.easeInOut(duration: 0.3), value: ending)
                                .accessibilityHidden(true)
                        }
                    } else if failed {
                        VStack(spacing: 12) {
                            Text("Couldn’t get the code. Check your connection.")
                                .font(Typography.font(15, weight: .regular))
                                .foregroundStyle(Neutral.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") { failed = false; attempt += 1 }
                                .font(Typography.font(15, weight: .semibold))
                                .foregroundStyle(FormGreen.accent)
                        }
                        .padding(.horizontal, 24)
                    } else {
                        ProgressView().frame(height: 62)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: 380)
        .background(EColor.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Neutral.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    /// "482 913": two groups of three, easier to read across a room.
    private func grouped(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// What's left of a code's minute, as a pie that empties clockwise.
private struct CodeTimer: View {
    var left: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.15))
            Pie(fraction: left).fill(color)
        }
    }

    private struct Pie: Shape {
        var fraction: Double

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            var path = Path()
            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                        endAngle: .degrees(-90 - 360 * max(0, min(1, fraction))), clockwise: true)
            path.closeSubpath()
            return path
        }
    }
}

/// Opens the code over everything, after Face ID (or the passcode): a tap on
/// Settings' row calls `open()`.
struct AccessCodeOpener: ViewModifier {
    @Binding var asked: Bool
    @State private var showing = false
    @State private var checking = false

    func body(content: Content) -> some View {
        content
            .onChange(of: asked) { _, on in
                guard on else { return }
                asked = false
                guard !checking else { return }
                checking = true
                Task {
                    // The Demo opens it on launch with no Face ID to answer.
                    let ok = DemoMode.parentOpen == "accesscode"
                        ? true : await ParentIdentity.confirm(reason: "Show your screen time access code")
                    checking = false
                    if ok { present(true) }
                }
            }
            // Over everything, with no slide up: the card itself pops in.
            .fullScreenCover(isPresented: $showing) {
                AccessCodeSheet { present(false) }
                    .presentationBackground(.clear)
            }
    }

    private func present(_ on: Bool) {
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) { showing = on }
    }
}
