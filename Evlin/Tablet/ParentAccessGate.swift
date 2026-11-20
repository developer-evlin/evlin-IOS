import SwiftUI

/// What the gear on the child's device opens (2026-11-19, the user's call):
/// straight to "Parents only", no list in front of it. The parent opens
/// Evlin on their phone, goes to Settings (the gear on the third tab) and
/// taps Screen time access code, confirms it's them with Face ID or the
/// passcode, and types the code shown here. Checked by the server
/// (`AccessCode`), so this device has to be online; the right code opens
/// `KidParentSettings`, every time the gear is tapped. Five wrong codes and
/// it waits a minute, doubling after.
/// Replaces "Parent controls · Needs parent approval" and its "Approve it in
/// Evlin on your phone." wait, which nothing on the phone ever answered.
struct ParentAccessGate: View {
    var onUnlocked: () -> Void
    var onCancel: () -> Void

    @State private var code = ""
    @FocusState private var typing: Bool
    @State private var wrongTick = 0
    @State private var shake: CGFloat = 0
    @State private var unlockedTick = 0
    @State private var message: String?
    @State private var checking = false
    // Kept across closing the sheet, so closing it doesn't reset the count.
    @AppStorage("evlin.accessCode.failures") private var failures = 0
    @AppStorage("evlin.accessCode.lockedUntil") private var lockedUntil: Double = 0

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private static let freeTries = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let wait = max(0, Int(lockedUntil - timeline.date.timeIntervalSince1970))
            ScrollView {
                VStack(spacing: 0) {
                    SecurityLottieView(size: kid.of(96, 120))
                        .padding(.top, kid.of(20, 28))

                    Text("Parents only")
                        .font(Typography.display(kid.of(24, 28), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .padding(.top, 12)
                    steps
                        .padding(.top, kid.of(20, 24))

                    codeBoxes(locked: wait > 0)
                        .padding(.top, kid.of(24, 28))
                        .modifier(Shake(amount: shake))

                    Group {
                        if wait > 0 {
                            Text("Too many tries. Try again in \(wait / 60):\(String(format: "%02d", wait % 60)).")
                        } else if let message {
                            Text(message)
                        } else {
                            Text(" ")
                        }
                    }
                    .font(Typography.font(kid.of(14, 16), weight: .bold))
                    .foregroundStyle(Color(hex: "EA580C"))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                    Button("Cancel", action: onCancel)
                        .font(Typography.font(kid.of(15, 17), weight: .bold))
                        .foregroundStyle(KidTheme.inkSoft)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: wait == 0) { _, open in if open { typing = true } }
        }
        .background(EPaperBackground())
        .presentationDetents([.large])
        .sensoryFeedback(.error, trigger: wrongTick)
        .sensoryFeedback(.success, trigger: unlockedTick)
        // Demo `-EvlinKidParentSettings` goes straight past it: no keyboard.
        .onAppear { typing = !DemoMode.kidParentSettings && Date().timeIntervalSince1970 >= lockedUntil }
    }

    // MARK: - What to do on the phone

    private var steps: some View {
        VStack(alignment: .leading, spacing: kid.of(12, 14)) {
            step(1, Text("Open Evlin on your phone."))
            step(2, Text("Tap \(Image(systemName: "clock.fill")) at the bottom, then \(Image(systemName: "gearshape.fill")) at the top."))
            step(3, Text("Tap **Screen time access code** and type it here."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(kid.of(16, 20))
        .background(KidTheme.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KidTheme.line))
    }

    private func step(_ n: Int, _ words: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(Typography.font(kid.of(14, 16), weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: kid.of(24, 28), height: kid.of(24, 28))
                .background(KidTheme.paperButton, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + kid.of(5, 6) }
            words
                .font(Typography.font(kid.of(15, 18), weight: .medium))
                .foregroundStyle(KidTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The code

    private func codeBoxes(locked: Bool) -> some View {
        ZStack {
            // The real field: invisible, under the boxes, taking the digits.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .focused($typing)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .disabled(locked || checking)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(AccessCode.digits))
                    if digits != new { code = digits; return }
                    if message != nil, !digits.isEmpty { message = nil }
                    if digits.count == AccessCode.digits { submit(digits) }
                }
            HStack(spacing: kid.of(8, 12)) {
                ForEach(0..<AccessCode.digits, id: \.self) { i in
                    let chars = Array(code)
                    let filled = i < chars.count
                    let current = i == chars.count && typing && !locked
                    Text(filled ? String(chars[i]) : "")
                        .font(.system(size: kid.of(26, 32), weight: .semibold, design: .rounded))
                        .foregroundStyle(KidTheme.ink)
                        .frame(width: kid.of(44, 56), height: kid.of(54, 66))
                        .background(KidTheme.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(current ? KidTheme.paperButton : KidTheme.line, lineWidth: current ? 2 : 1.5)
                        )
                    if i == 2 { Spacer().frame(width: kid.of(4, 8)) }
                }
            }
            .opacity(locked ? 0.45 : (checking ? 0.6 : 1))
            .contentShape(Rectangle())
            .onTapGesture { if !locked { typing = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Access code, \(code.count) of \(AccessCode.digits) digits")
    }

    private func submit(_ typed: String) {
        guard !checking else { return }
        checking = true
        Task {
            let answer: Bool?
            do { answer = try await AccessCode.check(typed) } catch { answer = nil }
            checking = false
            guard let answer else {
                // Checked only by the server: no connection, no way in.
                message = "Couldn’t check the code. Connect this device to the internet, then try again."
                code = ""
                return
            }
            answered(answer)
        }
    }

    private func answered(_ right: Bool) {
        if right {
            failures = 0
            lockedUntil = 0
            typing = false
            unlockedTick += 1
            // The keyboard goes down first: swapping this page out while
            // it was still moving crashed UIKit's keyboard host.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onUnlocked() }
            return
        }
        failures += 1
        wrongTick += 1
        withAnimation(.linear(duration: 0.35)) { shake += 1 }
        code = ""
        if failures >= Self.freeTries {
            let minutes = min(15.0, pow(2, Double(failures - Self.freeTries)))
            lockedUntil = Date().timeIntervalSince1970 + minutes * 60
            typing = false
            message = nil
        } else {
            message = "That code didn’t work. Check the code on your phone."
        }
    }
}

/// A side-to-side shake for a wrong code.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 4), y: 0))
    }
}
