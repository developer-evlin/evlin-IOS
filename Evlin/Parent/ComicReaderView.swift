import SwiftUI

// Full-screen comic reader. Mirrors the final web design from today's
// iteration: blurred backdrop fills the dead space around a moderately
// cropped (not full 9:16) panel image so both characters stay in frame,
// caption rendered as a clean gradient-scrim overlay (no baked-in banner).
struct ComicReaderView: View {
    let comic: ComicSeries
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var panels: [ComicPanel] { comic.panels }
    private var isLast: Bool { index == panels.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(panels[index].imageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 38)
                .brightness(-0.25)
                .saturation(1.3)
                .scaleEffect(1.2)
                .ignoresSafeArea()

            // This VStack deliberately does NOT ignore safe area — that lets
            // SwiftUI keep header/footer clear of the notch and home
            // indicator automatically instead of hand-computing insets.
            VStack(spacing: 0) {
                progressHeader

                Spacer(minLength: 0)

                GeometryReader { geo in
                    let w = geo.size.width
                    let h = w * 3 / 4
                    ZStack(alignment: .bottom) {
                        Image(panels[index].imageName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w, height: h)
                            .clipped()

                        LinearGradient(
                            colors: [.black.opacity(0.72), .black.opacity(0.4), .clear],
                            startPoint: .bottom, endPoint: .top
                        )
                        .frame(width: w, height: 130)

                        Text(panels[index].caption)
                            .font(Typography.font(15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 18)
                            .frame(width: w, alignment: .leading)
                    }
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                    .overlay(tapZones)
                }
                .frame(height: UIScreen.main.bounds.width * 3 / 4)

                Spacer(minLength: 0)

                footer
            }
        }
        .statusBarHidden()
    }

    private var progressHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(panels.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? Color.white : Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                }
            }
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(comic.title)
                        .font(Typography.font(13, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
                ShareLink(item: "Check out the comic \"\(comic.title)\" on Evlin — \(comic.excerpt)") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .onTapGesture { withAnimation { index = max(0, index - 1) } }
            Color.clear.contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .onTapGesture { withAnimation { index = min(panels.count - 1, index + 1) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(index + 1) / \(panels.count)")
                .font(Typography.font(12, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
            Button {
                if isLast { dismiss() } else { withAnimation { index += 1 } }
            } label: {
                HStack(spacing: 8) {
                    Text(isLast ? "Finish comic" : "Continue")
                        .font(Typography.font(15, weight: .heavy))
                    Image(systemName: isLast ? "checkmark" : "arrow.right")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.white)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .top))
    }
}
