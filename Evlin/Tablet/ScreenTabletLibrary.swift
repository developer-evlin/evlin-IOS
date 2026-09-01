import SwiftUI

struct ScreenTabletLibrary: View {
    @State private var comicTaskId: String?
    @State private var activeGuide: HowToGuide?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(Typography.display(26, weight: .heavy)).foregroundStyle(KidTheme.ink)

                    Text("Comics to explore").font(Typography.display(17, weight: .heavy)).foregroundStyle(KidTheme.ink).padding(.top, 10)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(TabletData.tasks.filter { !TabletData.comicPanels(for: $0.iconTaskId).isEmpty }) { task in
                            Button { comicTaskId = task.iconTaskId } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 11).fill(.white).frame(width: 38, height: 38)
                                        .overlay(Image(systemName: sfIcon(for: task.iconTaskId)).font(.system(size: 17)).foregroundStyle(KidTheme.greenDeep))
                                    Text(task.title).font(Typography.font(12.5, weight: .heavy)).foregroundStyle(KidTheme.ink).lineLimit(2)
                                    Label("Watch", systemImage: "play.circle.fill").font(Typography.font(10.5, weight: .bold)).foregroundStyle(KidTheme.greenDeep)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(KidTheme.cream)
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KidTheme.line, lineWidth: 2))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("How-to guides").font(Typography.display(18, weight: .heavy)).foregroundStyle(KidTheme.ink).padding(.top, 14)

                    VStack(spacing: 10) {
                        ForEach(TabletData.howToGuides) { guide in
                            Button { activeGuide = guide } label: {
                                HStack(spacing: 12) {
                                    Text(guide.emoji).font(.system(size: 28))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(guide.title).font(Typography.font(15, weight: .heavy)).foregroundStyle(KidTheme.ink)
                                        Text(guide.blurb).font(Typography.font(12.5, weight: .semibold)).foregroundStyle(KidTheme.inkSoft)
                                    }
                                    Spacer()
                                    Label("\(guide.count)", systemImage: "book.closed.fill").font(Typography.font(11.5, weight: .bold)).foregroundStyle(KidTheme.greenDeep)
                                }
                                .padding(14)
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
            }
            .background(KidTheme.background)
        }
        .fullScreenCover(item: Binding(get: { comicTaskId.map { IdentifiedString(value: $0) } }, set: { comicTaskId = $0?.value })) { wrapped in
            let task = TabletData.tasks.first { $0.iconTaskId == wrapped.value }
            ComicViewerView(title: task?.title ?? "", panels: TabletData.comicPanels(for: wrapped.value))
        }
        .fullScreenCover(item: $activeGuide) { guide in
            HowToGuideViewer(guide: guide)
        }
    }

    private func sfIcon(for taskId: String) -> String {
        switch taskId {
        case "t1": return "bed.double.fill"
        case "t2": return "function"
        case "t3": return "pawprint.fill"
        case "t4": return "book.fill"
        case "t5": return "mouth.fill"
        default: return "star.fill"
        }
    }
}

// Full-screen step-by-step viewer, one panel at a time with progress dots.
struct HowToGuideViewer: View {
    let guide: HowToGuide
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

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
