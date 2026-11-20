import SwiftUI

/// The child's device's settings, behind the screen time access code
/// (`ParentAccessGate`), asked for every time the gear is tapped
/// (2026-11-19, the user's call). The Screen Time apps (the app tokens
/// Apple's picker gives) and Log out, both only a front for now: neither
/// does anything yet.
struct KidParentSettings: View {
    var onDone: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(Typography.display(kid.of(26, 30), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Spacer()
                    Button("Done", action: onDone)
                        .font(Typography.font(kid.of(16, 18), weight: .bold))
                        .foregroundStyle(KidTheme.paperButton)
                }
                .padding(.top, kid.of(24, 32))

                heading("Screen Time apps")
                appsCard

                // Not wired yet (2026-11-19): a front only.
                Button {} label: {
                    Text("Log out")
                        .font(Typography.font(kid.of(16, 18), weight: .semibold))
                        .foregroundStyle(Color(hex: "D92D20"))
                        .frame(maxWidth: .infinity)
                        .frame(height: kid.of(54, 60))
                        .background(KidTheme.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KidTheme.line))
                }
                .buttonStyle(.plain)
                .padding(.top, kid.of(28, 36))
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(EPaperBackground())
        .presentationDetents([.large])
    }

    private func heading(_ words: String) -> some View {
        Text(words)
            .font(Typography.font(kid.of(15, 17), weight: .semibold))
            .foregroundStyle(KidTheme.inkSoft)
            .padding(.top, kid.of(24, 30))
            .padding(.bottom, 10)
    }

    /// The apps chosen in Apple's Screen Time picker (their app tokens): one
    /// row with the Family Sharing mark, the whole of it to press
    /// (2026-11-19, the user's call; an "Apps · None chosen yet" card with a
    /// separate Choose apps row before). Not wired yet: a front only.
    private var appsCard: some View {
        Button {} label: {
            HStack(spacing: 14) {
                FamilyMark(size: kid.of(36, 40), animated: false)
                Text("Apps")
                    .font(Typography.font(kid.of(16, 18), weight: .semibold))
                    .foregroundStyle(KidTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KidTheme.inkSoft)
            }
            .padding(16)
            .contentShape(Rectangle())
            .background(KidTheme.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KidTheme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apps")
    }
}
