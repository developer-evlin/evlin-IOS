import SwiftUI

// Kid-facing comic viewer — mirrors the web KidComic: all panels stacked in
// one scroll view (not swiped one at a time), with a read-aloud toggle.
struct ComicViewerView: View {
    let title: String
    let panels: [ComicPanel]
    @Environment(\.dismiss) private var dismiss
    @State private var speaking = false
    @State private var activeIndex = -1

    var body: some View {
        ZStack {
            LinearGradient(colors: [KidTheme.cream, Color(hex: "FDE7B0")], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    circleButton(icon: "xmark") { dismiss() }
                    Text(title)
                        .font(Typography.display(23, weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    circleButton(icon: speaking ? "stop.fill" : "speaker.wave.2.fill", filled: speaking) {
                        speaking.toggle()
                        activeIndex = speaking ? 0 : -1
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(panels.enumerated()), id: \.offset) { i, panel in
                            let isActive = activeIndex == i
                            Image(panel.imageName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isActive ? Color(hex: "FFC02E") : .clear, lineWidth: 4))
                                .opacity(speaking && !isActive ? 0.4 : 1)
                                .scaleEffect(isActive ? 1.015 : 1)
                                .shadow(color: isActive ? .black.opacity(0.22) : .clear, radius: 10, y: 4)
                        }
                        Text("Now it's your turn!")
                            .font(Typography.font(15, weight: .bold))
                            .foregroundStyle(KidTheme.ink.opacity(0.8))
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .statusBarHidden()
    }

    private func circleButton(icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(filled ? .white : KidTheme.ink)
                .frame(width: 42, height: 42)
                .background(filled ? KidTheme.green : .white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(KidTheme.ink, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
    }
}
