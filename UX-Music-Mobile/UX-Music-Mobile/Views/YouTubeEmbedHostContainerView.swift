import SwiftUI
import WebKit

/// Displays the single persistent `WKWebView` owned by `MusicPlayerService.youtubePlaybackHost`
/// by reparenting it into this representable's container view — it never creates or destroys the
/// web view itself. Showing/hiding `NowPlayingView` therefore only moves the web view between
/// superviews (or detaches it entirely); the web view instance, its JS state, and playback are
/// unaffected, so audio keeps playing while the sheet is closed (see `YouTubePlaybackHost`'s doc
/// comment for why this replaced the old per-screen `YouTubeEmbedPlayerView` usage here).
struct YouTubeEmbedHostContainerView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attach(to: uiView)
    }

    /// Moves the shared web view into `container` unless it is already there. Reparenting a
    /// `WKWebView` that stays alive and in-window the whole time does not interrupt its playback.
    private func attach(to container: UIView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Detaches (does not destroy) the shared web view so a dismissed `NowPlayingView` does not
    /// leave it parented under a view that is about to deallocate. The web view itself is owned by
    /// `YouTubePlaybackHost` and keeps running/playing off-screen.
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        for subview in uiView.subviews where subview is WKWebView {
            subview.removeFromSuperview()
        }
    }
}
