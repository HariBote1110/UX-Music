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

    /// Isolated `WKContentWorld` for the native bridge handler. See the long comment in `init()`
    /// for why this cannot simply be the default `.page` world.
    private static let bridgeContentWorld = WKContentWorld.world(name: "uxYouTubeBridge")

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
        // The native bridge handler is registered in an isolated content world instead of the
        // default `.page` world. `WKUserContentController.add(_:name:)` (the default-world
        // overload) injects `window.webkit.messageHandlers` into *every* frame's own `window`
        // object in this WKWebView — including cross-origin iframes such as YouTube's own
        // `youtube.com/embed/<id>` iframe nested inside our embed page. This is a documented
        // WKWebView quirk (Apple's own security guidance warns about it): the handler is not
        // confined to the top frame or to same-origin frames, so without this, YouTube's own script
        // running inside its iframe could detect `window.webkit.messageHandlers` and infer it is
        // running inside a native app's WKWebView. This was investigated as a candidate cause of
        // IFrame Player API error 150 ("embedding disallowed") on device, but did *not* turn out to
        // be the actual cause (see `progress/mobile-youtube-embed.md`) — real, unmodified mobile
        // Safari hits the same error 150 on the exact same loopback page, so this is a genuine
        // server-side mobile-web embedding restriction on YouTube's side, not anything detectable
        // client-side. Isolating the handler is kept regardless as a defence-in-depth hardening
        // (least-privilege exposure of the native bridge), independent of that investigation. A
        // small `WKUserScript` relay, injected into the same isolated world, listens for ordinary
        // `window.postMessage` traffic sent by the `.page`-world embed script (see
        // `YouTubeEmbedPlayer.buildEmbedHTML`) and forwards it to the native handler.
        webView.configuration.userContentController.add(self, contentWorld: Self.bridgeContentWorld, name: "uxYouTube")
        let relaySource = """
        window.addEventListener('message', function (ev) {
            if (!ev.data || ev.data.source !== 'ux-embed') return;
            try { window.webkit.messageHandlers.uxYouTube.postMessage(ev.data); } catch (e) { /* ignore */ }
        });
        """
        let relayScript = WKUserScript(
            source: relaySource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.bridgeContentWorld
        )
        webView.configuration.userContentController.addUserScript(relayScript)
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
