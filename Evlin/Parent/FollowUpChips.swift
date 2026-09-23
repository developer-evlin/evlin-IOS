import SwiftUI

/// Tappable answers to a question the assistant asked rather than guessed at.
///
/// The question itself is the message above these, so this is only the
/// shortcuts — typing a different answer always works and is never
/// foreclosed by the options offered.
struct FollowUpChips: View {
    let suggestions: [String]
    var onPick: (String) -> Void

    @State private var answered: String?

    var body: some View {
        if !suggestions.isEmpty {
            // Wraps rather than scrolls: a horizontal scroller would hide
            // options off-screen with nothing indicating they're there.
            // FlowLayout is the one already used by the add-task form's chips.
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { option in
                    Button {
                        guard answered == nil else { return }
                        answered = option
                        onPick(option)
                    } label: {
                        Text(option)
                            .font(Typography.font(14, weight: .semibold))
                            .foregroundStyle(answered == option ? .white : EColor.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(
                                Capsule().fill(answered == option ? Brand.greenDeep : EColor.primaryContainer)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(answered != nil)
                    .opacity(answered == nil || answered == option ? 1 : 0.4)
                }
            }
            .frame(maxWidth: bubbleMaxWidth + 60, alignment: .leading)
        }
    }
}
