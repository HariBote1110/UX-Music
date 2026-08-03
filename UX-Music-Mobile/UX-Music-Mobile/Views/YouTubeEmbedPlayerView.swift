import SwiftUI
import WebKit

/// WKWebView wrapper hosting the official YouTube IFrame Player for a single video ID.
///
/// Loaded from `YouTubeEmbedLoopbackServer`, an in-app loopback HTTP host, so the page has a
/// genuine `http://127.0.0.1:<port>` origin (see that type's doc comment for why the previous
/// `loadHTMLString(_:baseURL:)` fake-origin approach was unreliable on-device). Playback events
/// flow back to SwiftUI through the `uxYouTube` WKScriptMessageHandler; commands
/// (play/pause/seek) are pushed down via `evaluateJavaScript`.
/// Owns the live `WKWebView` so a SwiftUI screen can send playback commands (play/pause/seek)
/// from outside the `UIViewRepresentable` update cycle.
@MainActor
final class YouTubePlayerController: ObservableObject {
    fileprivate weak var webView: WKWebView?

    func send(_ command: YouTubeEmbedPlayer.Command) {
        webView?.evaluateJavaScript(YouTubeEmbedPlayer.commandScript(command), completionHandler: nil)
    }
}

struct YouTubeEmbedPlayerView: UIViewRepresentable {
    let videoID: String
    let controller: YouTubePlayerController
    /// Called on the main actor whenever the embedded player reports a bridge event.
    var onEvent: (YouTubeEmbedPlayer.BridgeEvent) -> Void = { _ in }

    /// Process-wide loopback host. One listener serves every embed page the app opens; it is
    /// cheap to keep running for the app's lifetime (mirrors `startEmbedHost`'s `sync.Once` on
    /// desktop, which never stops the server either).
    private static let loopbackServer = YouTubeEmbedLoopbackServer()

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "uxYouTube")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        controller.webView = webView

        Task { @MainActor in
            do {
                let port = try await Self.loopbackServer.ensureStarted()
                guard let url = YouTubeEmbedPlayer.loopbackPageURL(port: Int(port), videoID: videoID) else {
                    return
                }
                webView.load(URLRequest(url: url))
            } catch {
                context.coordinator.onEvent(.error(code: -1))
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "uxYouTube")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onEvent: (YouTubeEmbedPlayer.BridgeEvent) -> Void

        init(onEvent: @escaping (YouTubeEmbedPlayer.BridgeEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = YouTubeEmbedPlayer.parseBridgeMessage(body)
            else { return }
            onEvent(event)
        }
    }
}
