import SwiftUI
import WebKit

// Plays one vetted YouTube video inside the app.
//
// youtube-nocookie.com with rel=0: the privacy-enhanced host, and no
// end-screen suggestions. That second part is the point — every video a kid
// reaches here was searched for, checked against its real metadata and
// approved by a parent, and letting YouTube append "up next" at the end
// would hand back exactly the unvetted feed all of that exists to avoid.
private struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    var onFinished: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Inline rather than the fullscreen takeover player, so the quiz and
        // the rest of the screen stay visible around it.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // The page posts back through this when playback ends, which is what
        // lets "watched it" be a real signal instead of a button the kid can
        // press the moment the screen opens.
        config.userContentController.add(context.coordinator, name: "playbackEnded")

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
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.load(into: webView, videoID: videoID)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Without this the video keeps playing after the view goes away.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playbackEnded")
        webView.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onFinished: (() -> Void)?
        private(set) var loadedVideoID: String?

        init(onFinished: (() -> Void)?) {
            self.onFinished = onFinished
        }

        func load(into webView: WKWebView, videoID: String) {
            loadedVideoID = videoID
            webView.loadHTMLString(Self.playerHTML(videoID: videoID),
                                   baseURL: URL(string: "https://www.youtube-nocookie.com"))
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "playbackEnded" else { return }
            DispatchQueue.main.async { [onFinished] in onFinished?() }
        }

        // The iframe API is loaded from a local HTML shell rather than by
        // pointing the web view straight at an embed URL, because only the
        // API gives an onStateChange callback — a plain embed can't tell us
        // the video actually finished.
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
                  function onYouTubeIframeAPIReady() {
                    new YT.Player('player', {
                      videoId: '\(safeID)',
                      host: 'https://www.youtube-nocookie.com',
                      playerVars: {
                        rel: 0, playsinline: 1, modestbranding: 1,
                        iv_load_policy: 3, fs: 0
                      },
                      events: {
                        onStateChange: function (e) {
                          if (e.data === YT.PlayerState.ENDED) {
                            window.webkit.messageHandlers.playbackEnded.postMessage(true);
                          }
                        }
                      }
                    });
                  }
                </script>
              </body>
            </html>
            """
        }
    }
}

/// A vetted video, framed like the rest of the app's media slots, with the
/// same manual reload affordance ScreenTimePINVideoView has — a kid staring
/// at a stalled player has no other way out of it.
struct YouTubeEmbedView: View {
    let videoID: String
    var onFinished: (() -> Void)?

    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            YouTubePlayerView(videoID: videoID, onFinished: onFinished)
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
