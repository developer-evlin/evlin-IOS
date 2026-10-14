import SwiftUI

/// A bundle's cover: today's lesson's still with the subject's colour behind
/// it. The same tile on the parent's Library and the kid's.
struct LibraryBundleCover: View {
    let bundle: LibraryBundle
    let lesson: LibraryLesson
    var cornerRadius: CGFloat = 14

    var body: some View {
        VideoThumbnail(url: lesson.thumbnailURL, durationSeconds: lesson.seconds, cornerRadius: cornerRadius)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(bundle.subject.tint.opacity(0.15)))
            .overlay(alignment: .topLeading) {
                Label(bundle.subject.name, systemImage: bundle.subject.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(bundle.subject.tint))
                    .padding(8)
            }
    }
}

/// One lesson, full screen, in YouTube's own embedded player with its
/// channel named underneath. Shared by the parent's preview and the kid's
/// "Start today's lesson". `onFinished` runs when the video plays to the end.
struct LibraryPlayerView: View {
    let lesson: LibraryLesson
    var subtitle: String? = nil
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.06)))
                }
                .accessibilityLabel("Close")
                Spacer()
            }

            if finished {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Brand.greenDeep)
                    Text("All done!").font(Typography.display(24, weight: .heavy)).foregroundStyle(Brand.ink)
                    Button { dismiss() } label: {
                        Text("Back to the Library")
                            .font(Typography.font(16, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28).frame(height: 50)
                            .background(Capsule().fill(Brand.greenDeep))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            } else {
                YouTubeEmbedView(videoID: lesson.youtubeId, onFinished: {
                    finished = true
                    onFinished?()
                })
            }

            VStack(alignment: .leading, spacing: 4) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(Typography.font(12, weight: .bold)).tracking(0.5)
                        .foregroundStyle(Brand.inkSoft)
                }
                Text(lesson.title)
                    .font(Typography.display(24, weight: .heavy))
                    .foregroundStyle(Brand.ink)
                Text("\(lesson.channel) on YouTube · \(lesson.minutes) min")
                    .font(Typography.font(15, weight: .semibold))
                    .foregroundStyle(Brand.inkSoft)
            }

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .background(KidTheme.background.ignoresSafeArea())
    }
}
