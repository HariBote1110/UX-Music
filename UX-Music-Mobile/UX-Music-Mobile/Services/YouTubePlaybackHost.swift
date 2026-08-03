import Foundation
import WebKit

/// Owns a single, long-lived `WKWebView` for YouTube library playback, kept alive by
/// `MusicPlayerService` for the app process's lifetime — not created/torn down by whichever
/// SwiftUI screen currently happens to show it.
///
/// Before this type existed, `NowPlayingView` created its own `YouTubeEmbedPlayerView`
/// (`UIViewRepresentable`), so the WKWebView (and the video/audio it was playing) was destroyed
/// the moment Now Playing was dismissed — a YouTube song stopped the instant the user went back
/// to their Library, unlike a local file which keeps playing via `AVAudioEngine`. This host makes
/// YouTube songs behave the same way: the WKWebView is created once, lives for as long as the app
/// is in the foreground, and SwiftUI only ever *borrows* it for display (see
/// `YouTubeEmbedHostContainerView`) — reparenting the same view into whatever container is
/// currently on screen, or into no container at all while Now Playing is closed.
@MainActor
final class YouTubePlaybackHost: NSObject, WKScriptMessageHandler {
    let webView: WKWebView

    /// Called whenever the embedded player reports a bridge event (ready/state/time/error).
    var onEvent: ((YouTubeEmbedPlayer.BridgeEvent) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: "uxYouTube")
    }

    /// Loads the loopback embed page for `videoID`, starting the shared loopback server first if
    /// this is the first video played this session.
    func load(videoID: String) async throws {
        let port = try await YouTubeEmbedLoopbackServer.shared.ensureStarted()
        guard let url = YouTubeEmbedPlayer.loopbackPageURL(port: Int(port), videoID: videoID) else {
            throw YouTubeEmbedPlayer.EmbedPlayerError.invalidVideoID
        }
        webView.load(URLRequest(url: url))
    }

    func send(_ command: YouTubeEmbedPlayer.Command) {
        webView.evaluateJavaScript(YouTubeEmbedPlayer.commandScript(command), completionHandler: nil)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = YouTubeEmbedPlayer.parseBridgeMessage(body)
        else { return }
        MainActor.assumeIsolated {
            onEvent?(event)
        }
    }
}
