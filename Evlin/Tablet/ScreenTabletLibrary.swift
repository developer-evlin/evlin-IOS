import SwiftUI

struct ScreenTabletLibrary: View {
    @State private var activeGuide: HowToGuide?

    // A browse list, not a canvas like the calendar, so the whole page
    // still caps to KidAdaptive's content column rather than spreading
    // edge to edge.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(Typography.display(kid.of(26, 30), weight: .heavy)).foregroundStyle(KidTheme.ink)

                    Text("How-to guides").font(Typography.display(kid.of(18, 21), weight: .heavy)).foregroundStyle(KidTheme.ink).padding(.top, 10)

                    VStack(spacing: 10) {
                        ForEach(TabletData.howToGuides) { guide in
                            Button { activeGuide = guide } label: {
                                HStack(spacing: 12) {
                                    Text(guide.emoji).font(.system(size: kid.of(28, 32)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(guide.title).font(Typography.font(kid.of(15, 17), weight: .heavy)).foregroundStyle(KidTheme.ink)
                                        Text(guide.blurb).font(Typography.font(kid.of(12.5, 14), weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                                    }
                                    Spacer()
                                    Label("\(guide.count)", systemImage: "book.closed.fill").font(Typography.font(kid.of(11.5, 13), weight: .bold)).foregroundStyle(KidTheme.greenDeep)
                                }
                                .padding(kid.of(14, 18))
                                .background(Color(hex: "F0F4FF"))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .kidContentColumn(kid.contentMaxWidth)
            }
            .background(KidTheme.background)
        }
        .fullScreenCover(item: $activeGuide) { guide in
            HowToGuideViewer(guide: guide)
        }
    }
}

// Full-screen step-by-step viewer, one panel at a time with progress dots.
struct HowToGuideViewer: View {
    let guide: HowToGuide
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    private var isLast: Bool { step == guide.count - 1 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [KidTheme.cream, Color(hex: "FDE7B0")], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    circleButton(icon: "xmark") { dismiss() }
                    Text(guide.title).font(Typography.display(22, weight: .heavy)).foregroundStyle(KidTheme.ink)
                        .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    circleButton(icon: "speaker.wave.2.fill") {}
                }
                .padding(.horizontal, 20).padding(.top, 8)

                HStack(spacing: 6) {
                    ForEach(0..<guide.count, id: \.self) { i in
                        Capsule().fill(i <= step ? KidTheme.green : Color(hex: "E6DCB0"))
                            .frame(width: i == step ? 22 : 8, height: 8)
                    }
                }
                .padding(.vertical, 10)

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Text("STEP \(step + 1) OF \(guide.count)")
                        .font(Typography.font(14, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(KidTheme.greenDeep)
                    Image(TabletData.guidePanelImage(guide, step: step))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                        .padding(.horizontal, 20)
                        .kidContentColumn(kid.contentMaxWidth)
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    if step > 0 {
                        Button("Back") { step -= 1 }
                            .font(Typography.display(16, weight: .heavy))
                            .foregroundStyle(KidTheme.ink)
                            .padding(.horizontal, 20).frame(height: 56)
                            .background(.white)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(KidTheme.ink, lineWidth: 2.5))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    Button(isLast ? "I made it! 🎉" : "Next step") {
                        if isLast { dismiss() } else { step += 1 }
                    }
                    .font(Typography.display(18, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(
                        // A solid offset duplicate behind the face, not a
                        // `.shadow()` — that would shadow the label text
                        // too, ghosting a second copy of it below.
                        ZStack {
                            RoundedRectangle(cornerRadius: 18).fill(KidTheme.greenDeep).offset(y: 4)
                            RoundedRectangle(cornerRadius: 18).fill(KidTheme.green)
                        }
                        // Flattened into one layer first so any future
                        // press/disabled dimming can't split the two
                        // rectangles apart into a smeared double edge.
                        .compositingGroup()
                    )
                    // Missing here (every other button in this file has it)
                    // meant this fell back to the system default button
                    // style, which dims the whole label on touch-down — the
                    // face and its offset base rectangle faded together,
                    // exposing the seam between them as a smeared double
                    // edge for as long as it was held down.
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .kidContentColumn(kid.contentMaxWidth)
            }
        }
        .statusBarHidden()
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KidTheme.ink)
                .frame(width: 42, height: 42)
                .background(.white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(KidTheme.ink, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
    }
}
