import SwiftUI
import UIKit

/// Displays the single persistent `WKWebView` owned by `MusicPlayerService.youtubePlaybackHost`
/// by reparenting it into this representable's container view — it never creates or destroys the
/// web view itself. Showing/hiding `NowPlayingView` therefore only moves the web view between
/// superviews (or parks it in the key window); the web view instance, its JS state, and playback
/// are unaffected, so audio keeps playing while the sheet is closed (see `YouTubePlaybackHost`'s
/// doc comment for why this replaced the old per-screen `YouTubeEmbedPlayerView` usage here).
@MainActor
struct YouTubeEmbedHostContainerView: UIViewRepresentable {
    let host: YouTubePlaybackHost

    func makeUIView(context: Context) -> UIView {
        let container = YouTubeEmbedContainerView(host: host)
        container.backgroundColor = .black
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let container = uiView as? YouTubeEmbedContainerView else { return }
        container.host = host
        attach(to: container)
    }

    /// Moves the shared web view into `container` once the container is in a window. Reparenting a
    /// `WKWebView` that stays alive and in-window the whole time does not interrupt its playback.
    private func attach(to container: YouTubeEmbedContainerView) {
        container.attachWebViewIfPossible()
    }

    /// Parks the shared web view in the key window so a dismissed `NowPlayingView` does not leave
    /// it outside a window hierarchy. The web view itself is owned by `YouTubePlaybackHost` and
    /// keeps running/playing off-screen.
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Only park if this container still owns the web view — a newer container may already
        // have borrowed it, and parking would pull it off screen.
        guard let host = (uiView as? YouTubeEmbedContainerView)?.host, host.webView.superview === uiView else { return }
        host.park()
    }
}

@MainActor
private final class YouTubeEmbedContainerView: UIView {
    weak var host: YouTubePlaybackHost?

    init(host: YouTubePlaybackHost) {
        self.host = host
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attachWebViewIfPossible() {
        guard window != nil, let host else { return }
        if host.webView.superview !== self {
            host.webView.translatesAutoresizingMaskIntoConstraints = true
            host.webView.autoresizingMask = []
            addSubview(host.webView)
        }
        host.layoutWebView(in: self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachWebViewIfPossible()
        } else if let host, host.webView.superview === self {
            host.park()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host, host.webView.superview === self else { return }
        host.layoutWebView(in: self)
    }
}
