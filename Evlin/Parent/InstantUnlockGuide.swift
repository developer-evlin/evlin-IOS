import SwiftUI

/// What the days left on Profile's Instant unlock row open, as a full sheet: the
/// days so far, a few lines on what it is and how it's earned, and its switch,
/// frozen until it's earned.
struct InstantUnlockGuide: View {
    @ObservedObject var child: Child
    var onTurnOn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = UnlockTrustStore.shared

    private var trust: UnlockTrust { store.trust(for: child.id) }
    private var canTurnOn: Bool { trust.earned && !child.instantUnlock }

    private var headline: String {
        if child.instantUnlock { return "It's on for \(child.name)" }
        if trust.earned { return "\(child.name) has earned it" }
        return "\(trust.daysLeft) more \(trust.daysLeft == 1 ? "day" : "days") to go"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Instant unlock")
                            .font(Typography.font(28, weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(Neutral.ink)
                        Spacer()
                        SheetCloseButton { dismiss() }
                    }
                    .padding(.top, 28)

                    InstantUnlockDays(done: trust.earned ? UnlockTrust.daysNeeded : trust.streak)
                        .padding(.top, 20)

                    Text(headline)
                        .font(Typography.font(21, weight: .heavy))
                        .foregroundStyle(Neutral.ink)
                        .padding(.top, 24)
                    paragraph("Instant unlock gives \(child.name) screen time as soon as every task is done, without waiting for your approval. You can still review the work later.")
                    if !trust.earned {
                        paragraph("For instant unlock to be activated, you and \(child.name) must use the app for at least three consecutive days. This helps make sure \(child.name) builds strong habits. A day counts when every task is completed.")
                    }
                    paragraph("Once \(child.name) earns your trust, you can turn it on, but we recommend at least 21 days first. If \(child.name) starts falling behind, turn it off.")
                    if !trust.earned {
                        frozenSwitch
                            .padding(.top, 20)
                    }
                }
                .padding(.bottom, 16)
            }

            Button {
                if canTurnOn { onTurnOn() }
                dismiss()
            } label: {
                Text(canTurnOn ? "Turn it on" : "Got it")
                    .font(Typography.font(17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(FormGreen.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .background(Rectangle().fill(EColor.surface).ignoresSafeArea())
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Typography.font(16, weight: .medium))
            .foregroundStyle(Neutral.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    // The switch the parent will have, off and not answering yet.
    private var frozenSwitch: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instant unlock")
                    .font(Typography.font(16, weight: .bold))
                    .foregroundStyle(Neutral.ink)
                Text("Only you can turn this on, once the three days are done.")
                    .font(Typography.font(13, weight: .medium))
                    .foregroundStyle(Neutral.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            EToggle(on: .constant(false), color: StatusCardStyle.green)
                .disabled(true)
                .opacity(0.5)
        }
        .padding(16)
        .background(EColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Neutral.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instant unlock, off. Only you can turn this on, once the three days are done.")
    }
}

/// The days earned so far along a line, and the padlock after them. As the sheet
/// opens the newest day plays once: the line reaches it and it ticks, then the
/// next day's ring draws itself green, or the padlock opens. Then it holds still.
private struct InstantUnlockDays: View {
    var done: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit: Int
    @State private var lines: Int
    @State private var nextRing = 0.0
    @State private var opened = false

    private static let node: CGFloat = 54
    // Long enough for the sheet to finish rising, so it's seen.
    private static let sheetRise = 0.7

    init(done: Int) {
        self.done = done
        _lit = State(initialValue: max(0, done - 1))
        _lines = State(initialValue: max(0, done - 2))
    }

    var body: some View {
        let days = UnlockTrust.daysNeeded
        HStack(spacing: 0) {
            ForEach(0..<days, id: \.self) { i in
                day(i)
                connector(filled: i < lines)
            }
            padlock
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .padding(.horizontal, 24)
        .background(Neutral.tile, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(days) days")
        .task(id: done) { await play() }
    }

    private func play() async {
        let days = UnlockTrust.daysNeeded
        if reduceMotion {
            lit = done
            lines = done >= days ? days : max(0, done - 1)
            nextRing = 1
            opened = done >= days
            return
        }
        try? await Task.sleep(for: .seconds(Self.sheetRise))
        withAnimation(.easeInOut(duration: 0.35)) { lines = max(0, done - 1) }
        if done > 1 { try? await Task.sleep(for: .seconds(0.3)) }
        withAnimation(.spring(duration: 0.45, bounce: 0.4)) { lit = done }
        try? await Task.sleep(for: .seconds(0.4))
        if done >= days {
            withAnimation(.easeInOut(duration: 0.35)) { lines = days }
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.spring(duration: 0.45, bounce: 0.3)) { opened = true }
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { nextRing = 1 }
        }
    }

    private func day(_ i: Int) -> some View {
        let ticked = i < lit
        return ZStack {
            Circle().fill(EColor.card)
            Circle().strokeBorder(Neutral.border, lineWidth: 2)
            if i == done {
                Circle()
                    .inset(by: 1.25)
                    .trim(from: 0, to: nextRing)
                    .stroke(StatusCardStyle.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(i + 1)")
                .font(Typography.font(19, weight: .bold))
                .foregroundStyle(Neutral.secondary)
                .opacity(ticked ? 0 : 1)
            Circle().fill(StatusCardStyle.green).scaleEffect(ticked ? 1 : 0.001)
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
                .scaleEffect(ticked ? 1 : 0.001)
        }
        .frame(width: Self.node, height: Self.node)
    }

    private func connector(filled: Bool) -> some View {
        Capsule()
            .fill(Neutral.border)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(StatusCardStyle.green).frame(width: filled ? geo.size.width : 0)
                }
            }
            .frame(minWidth: 4, maxWidth: .infinity)
    }

    private var padlock: some View {
        ZStack {
            Circle().fill(EColor.card)
            Circle().strokeBorder(Neutral.border, lineWidth: 2)
            Circle().fill(StatusCardStyle.green).scaleEffect(opened ? 1 : 0.001)
            LockGlyph(open: opened ? 1 : 0)
                .stroke(opened ? .white : Neutral.secondary,
                        style: StrokeStyle(lineWidth: 2.75, lineCap: .round, lineJoin: .round))
                .frame(width: 30, height: 30)
        }
        .frame(width: Self.node, height: Self.node)
    }
}
