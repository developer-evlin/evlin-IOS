import SwiftUI

struct LessonReaderView: View {
    let lesson: SlideLesson
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var slides: [LessonSlide] { lesson.slides }
    private var isLast: Bool { index == slides.count - 1 }
    private var slide: LessonSlide { slides[index] }

    var body: some View {
        ZStack {
            slide.gradient.ignoresSafeArea()
            RadialGradient(colors: [.white.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 400)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(slides.indices, id: \.self) { i in
                        Capsule()
                            .fill(i <= index ? Color.white : Color.white.opacity(0.25))
                            .frame(maxWidth: .infinity)
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: EIcon.sf(lesson.icon)).foregroundStyle(.white)
                        Text(lesson.title).font(Typography.font(12, weight: .heavy)).foregroundStyle(.white)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ZStack {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation { index = max(0, index - 1) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation { index = min(slides.count - 1, index + 1) } }
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 16) {
                        if slide.kind == "cover" {
                            slideGlyph(big: true)
                            VStack(alignment: .leading, spacing: 12) {
                                Text(slide.kicker.uppercased()).font(Typography.font(11, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                                Text(slide.headline).font(Typography.font(34, weight: .heavy)).foregroundStyle(.white)
                                if let sub = slide.sub {
                                    Text(sub).font(Typography.font(14, weight: .regular)).foregroundStyle(.white.opacity(0.82))
                                }
                            }
                        } else if slide.kind == "takeaway" {
                            Text(slide.kicker.uppercased()).font(Typography.font(11, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                            Text(slide.headline).font(Typography.font(27, weight: .heavy)).foregroundStyle(.white)
                            VStack(spacing: 12) {
                                ForEach(Array((slide.points ?? []).enumerated()), id: \.offset) { i, p in
                                    HStack(spacing: 14) {
                                        Text("\(i + 1)")
                                            .font(Typography.font(13, weight: .heavy))
                                            .frame(width: 28, height: 28)
                                            .background(.white.opacity(0.9))
                                            .clipShape(Circle())
                                        Text(p).font(Typography.font(15, weight: .bold)).foregroundStyle(.white)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(14)
                                    .background(.white.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.16)))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                            }
                        } else {
                            slideGlyph(big: false)
                            Text(slide.kicker.uppercased()).font(Typography.font(11, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.72))
                            Text(slide.headline).font(Typography.font(24, weight: .heavy)).foregroundStyle(.white)
                            if let body = slide.body {
                                Text(body).font(Typography.font(15, weight: .regular)).foregroundStyle(.white.opacity(0.86))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 14) {
                    Text("\(index + 1) / \(slides.count)").font(Typography.font(12, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                    Button {
                        if isLast { dismiss() } else { withAnimation { index += 1 } }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isLast ? "Finish lesson" : "Continue").font(Typography.font(15, weight: .heavy))
                            Image(systemName: isLast ? "checkmark" : "arrow.right").font(.system(size: 16, weight: .bold))
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
                .padding(.bottom, 20)
            }
        }
        .statusBarHidden()
    }

    private func slideGlyph(big: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.1)).frame(width: 220, height: 220)
            Circle().strokeBorder(.white.opacity(0.06)).frame(width: 300, height: 300)
            RoundedRectangle(cornerRadius: big ? 34 : 28)
                .fill(.white.opacity(0.14))
                .frame(width: big ? 124 : 96, height: big ? 124 : 96)
                .overlay(
                    Image(systemName: EIcon.sf(slide.icon))
                        .font(.system(size: big ? 50 : 38, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .frame(height: big ? 220 : 180)
        .frame(maxWidth: .infinity)
    }
}
