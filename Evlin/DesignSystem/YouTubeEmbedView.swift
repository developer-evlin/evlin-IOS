import SwiftUI
import WebKit

// Plays one parent-approved YouTube video inside the app — today's videos
// (VideoQueueData). The only place in Evlin a video plays.
//
// youtube-nocookie.com with rel=0: the privacy-enhanced host, and no
// end-screen suggestions. That second part is the point — every video a kid
// reaches here was searched for, filtered against its real metadata and
// approved by a parent, and letting YouTube append "up next" at the end
// would hand back exactly the unvetted feed all of that exists to avoid.
// For the same reason no link may leave the player: tapping the YouTube
// logo or the title would otherwise open youtube.com inside the app.
private struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    var onFinished: (() -> Void)?
    var onProgress: ((Int) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // YouTube's own fullscreen button. Leaving fullscreen is handled in
        // the page (see playerHTML): it's exited the moment the video ends,
        // before the app takes the player away.
        config.preferences.isElementFullscreenEnabled = true
        // The page posts back through these when playback ends, and every
        // few seconds with how long it has actually been playing — what the
        // daily allowance counts, rather than the time the screen was open.
        config.userContentController.add(context.coordinator, name: "playbackEnded")
        config.userContentController.add(context.coordinator, name: "playedSeconds")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(into: webView, videoID: videoID)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFinished = onFinished
        context.coordinator.onProgress = onProgress
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.load(into: webView, videoID: videoID)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Without this the video keeps playing after the view goes away.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playbackEnded")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playedSeconds")
        webView.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished, onProgress: onProgress) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onFinished: (() -> Void)?
        var onProgress: ((Int) -> Void)?
        private(set) var loadedVideoID: String?

        init(onFinished: (() -> Void)?, onProgress: ((Int) -> Void)?) {
            self.onFinished = onFinished
            self.onProgress = onProgress
        }

        func load(into webView: WKWebView, videoID: String) {
            loadedVideoID = videoID
            webView.loadHTMLString(Self.playerHTML(videoID: videoID),
                                   baseURL: URL(string: "https://www.youtube-nocookie.com"))
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "playbackEnded":
                DispatchQueue.main.async { [onFinished] in onFinished?() }
            case "playedSeconds":
                guard let seconds = (message.body as? NSNumber)?.intValue else { return }
                DispatchQueue.main.async { [onProgress] in onProgress?(seconds) }
            default:
                break
            }
        }

        // Keeps the kid inside the player. The embed's own frames load
        // freely; anything that would replace the page or open a window (the
        // YouTube logo, the title, "watch on YouTube") is cancelled.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.targetFrame else { return decisionHandler(.cancel) }
            if target.isMainFrame && navigationAction.navigationType == .linkActivated {
                return decisionHandler(.cancel)
            }
            if target.isMainFrame, let host = navigationAction.request.url?.host,
               host != "www.youtube-nocookie.com" {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // The iframe API is loaded from a local HTML shell rather than by
        // pointing the web view straight at an embed URL, because only the
        // API gives an onStateChange callback — a plain embed can't tell us
        // the video actually finished or is playing.
        private static func playerHTML(videoID: String) -> String {
            let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return """
            <!DOCTYPE html>
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
                <style>
                  html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
                  #player { width: 100%; height: 100%; }
                </style>
              </head>
              <body>
                <div id="player"></div>
                <script src="https://www.youtube.com/iframe_api"></script>
                <script>
                  var player, played = 0;
                  function onYouTubeIframeAPIReady() {
                    player = new YT.Player('player', {
                      videoId: '\(safeID)',
                      host: 'https://www.youtube-nocookie.com',
                      playerVars: {
                        rel: 0, playsinline: 1, modestbranding: 1,
                        iv_load_policy: 3, fs: 1, disablekb: 1, autoplay: 0
                      },
                      events: {
                        onStateChange: function (e) {
                          if (guardVideo()) return;
                          if (e.data === YT.PlayerState.ENDED) {
                            leaveFullscreen();
                            window.webkit.messageHandlers.playedSeconds.postMessage(played);
                            window.webkit.messageHandlers.playbackEnded.postMessage(true);
                          }
                        }
                      }
                    });
                  }
                  function leaveFullscreen() {
                    var d = document;
                    if (d.fullscreenElement && d.exitFullscreen) d.exitFullscreen();
                    else if (d.webkitFullscreenElement && d.webkitExitFullscreen) d.webkitExitFullscreen();
                  }
                  // Only the approved video plays here. Anything YouTube's
                  // player offers instead (a suggestion while paused, an
                  // end-screen video) is stopped at once, and the approved
                  // video is put back where the child left it, paused.
                  var lastTime = 0;
                  function guardVideo() {
                    if (!player || !player.getVideoUrl) return false;
                    var m = (player.getVideoUrl() || '').match(/[?&]v=([^&#]+)/);
                    if (!m || m[1] === '\(safeID)') return false;
                    player.cueVideoById('\(safeID)', lastTime);
                    return true;
                  }
                  // Seconds spent actually playing, not the position: seeking
                  // ahead doesn't spend the allowance, and pausing doesn't either.
                  setInterval(function () {
                    if (guardVideo()) return;
                    if (player && player.getPlayerState && player.getPlayerState() === YT.PlayerState.PLAYING) {
                      played += 1;
                      lastTime = player.getCurrentTime();
                      window.webkit.messageHandlers.playedSeconds.postMessage(played);
                    }
                  }, 1000);
                </script>
              </body>
            </html>
            """
        }
    }
}

/// An approved video, framed like the rest of the app's media slots, with the
/// same manual reload affordance ScreenTimePINVideoView has — a kid staring
/// at a stalled player has no other way out of it.
///
/// `onProgress` gets the seconds this video has been playing since it
/// appeared (each second, while playing). A reload starts that count again.
struct YouTubeEmbedView: View {
    let videoID: String
    var onFinished: (() -> Void)?
    var onProgress: ((Int) -> Void)?

    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            YouTubePlayerView(videoID: videoID, onFinished: onFinished, onProgress: onProgress)
                .id(reloadID)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
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

/// A video's still, with its length in the corner — the same tile on the
/// parent's card and list and on the kid's list.
struct VideoThumbnail: View {
    let url: String?
    let durationSeconds: Int
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.black.opacity(0.08)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let url, let u = URL(string: url) {
                    AsyncImage(url: u) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(VideoFormat.duration(durationSeconds))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75)))
                    .padding(5)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
