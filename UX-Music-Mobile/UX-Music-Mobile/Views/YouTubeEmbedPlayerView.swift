import SwiftUI
import WebKit

/// WKWebView wrapper hosting the official YouTube IFrame Player for a single video ID.
///
/// Loaded via `loadHTMLString(_:baseURL:)` with `baseURL = http://127.0.0.1` — see the doc
/// comment on `YouTubeEmbedPlayer` for why this avoids IFrame API error 153 without needing a
/// real local HTTP server on-device. Playback events flow back to SwiftUI through the
/// `uxYouTube` WKScriptMessageHandler; commands (play/pause/seek) are pushed down via
/// `evaluateJavaScript`.
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

    private static let embedOrigin = URL(string: "http://127.0.0.1")

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

        if let html = try? YouTubeEmbedPlayer.buildEmbedHTML(videoID: videoID) {
            webView.loadHTMLString(html, baseURL: Self.embedOrigin)
        }
        controller.webView = webView
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
