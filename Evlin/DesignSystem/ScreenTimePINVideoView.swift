import SwiftUI
import AVFoundation

// Looping, muted, controls-free playback of a bundled screen recording —
// used for the one onboarding step where showing the real iOS Settings flow
// (Resources/Media/<name>.mp4) beats illustrating it with a Lottie animation
// like SecurityLottieView does elsewhere in this flow.
private struct LoopingVideoView: UIViewRepresentable {
    var resourceName: String
    var resourceExtension: String = "mp4"

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else {
            return view
        }
        let queuePlayer = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        // AVPlayerLooper — Apple's documented gapless-loop pattern; a naive
        // seek-to-zero on AVPlayerItemDidPlayToEndTime shows a visible
        // stutter/flash at the loop point.
        context.coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.isMuted = true
        view.playerLayer.player = queuePlayer
        view.playerLayer.videoGravity = .resizeAspectFill
        queuePlayer.play()
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        // Retains the looper — AVPlayerLooper stops looping the instant it
        // deallocates, so it can't be a throwaway local.
        var looper: AVPlayerLooper?
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// Rounded, bordered frame matching this onboarding flow's other illustration
// slots (SecurityLottieView, ContractSignLottieView, …). The source file
// itself is a wide 1920×1080 canvas with the phone mockup centered in mostly
// empty space — displaying it at that raw 16:9 shrank the actual content, so
// this crops to the phone's own ~391:449 proportions instead (measured from
// a frame of the source) and relies on videoGravity = .resizeAspectFill
// above to do the cropping.
struct ScreenTimePINVideoView: View {
    // Forces LoopingVideoView to fully tear down and recreate its
    // AVQueuePlayer from scratch — a kid (this step is also shown on the
    // KID onboarding chain) who finds the video frozen has no other way to
    // recover it, since AVPlayerLooper has no built-in stall detection or
    // public "just restart" call.
    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LoopingVideoView(resourceName: "screentimePIN")
                .id(reloadID)
                .aspectRatio(391.0 / 449.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
                )

            Button { reloadID = UUID() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
