import AVKit
import Foundation
import UIKit
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
/// currently on screen, or into a small off-screen holder attached to the key window while Now
/// Playing is closed.
@MainActor
final class YouTubePlaybackHost: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private let parkingView: UIView
    /// What the owner asked for (cellular policy); the effective value also depends on visibility.
    private var preferredLowQuality = false
    /// The effective value last pushed to the page, so the JS command is sent only on change.
    private var appliedLowQuality = false
    /// Whether the effective low-quality path is in force. A parked or otherwise unseen video is
    /// always low quality (battery/heat); see `YouTubeEmbedPlayer.effectiveLowQuality`.
    var isLowQuality: Bool {
        YouTubeEmbedPlayer.effectiveLowQuality(preferred: preferredLowQuality, isVideoVisible: isVideoVisible)
    }
    /// Visible = reparented into a real container, or presenting in PiP / fullscreen.
    var isVideoVisible: Bool {
        if pictureInPictureMode == .pictureInPicture || pictureInPictureMode == .fullscreen { return true }
        guard let superview = webView.superview else { return false }
        return superview !== parkingView
    }
    private var pictureInPictureFrame: WKFrameInfo?
    private var pictureInPictureSupports = false
    private var fullscreenSupports = false
    private var pictureInPictureEnterContinuation: CheckedContinuation<Bool, Never>?
    private var fullscreenEnterContinuation: CheckedContinuation<Bool, Never>?
    private(set) var pictureInPictureMode: YouTubeEmbedPlayer.PresentationMode = .unknown
    private(set) var isPictureInPictureAvailable = false
    private(set) var isFullscreenAvailable = false

    /// Physical-pixel target used to let YouTube's native player-size quality selection settle
    /// at its approximately 360p floor on cellular data.
    private static let lowQualityTargetPixelSize = CGSize(width: 256, height: 144)

    /// Called whenever the embedded player reports a bridge event (ready/state/time/error/quality).
    var onEvent: ((YouTubeEmbedPlayer.BridgeEvent) -> Void)?

    /// Called when presentation mode or availability changes for the current embedded video.
    var onPictureInPictureModeChange: ((YouTubeEmbedPlayer.PresentationMode) -> Void)?

    /// Isolated `WKContentWorld` for the native bridge handler. See the long comment in `init()`
    /// for why this cannot simply be the default `.page` world.
    private static let bridgeContentWorld = WKContentWorld.world(name: "uxYouTubeBridge")
    private static let pictureInPictureContentWorld = WKContentWorld.world(name: "uxYouTubePiP")

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        let parkingView = UIView(frame: CGRect(x: -256, y: -144, width: 256, height: 144))
        self.webView = webView
        self.parkingView = parkingView
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

        webView.configuration.userContentController.add(
            self,
            contentWorld: Self.pictureInPictureContentWorld,
            name: "uxYouTubePiP"
        )
        let pictureInPictureSource = """
        (function () {
            'use strict';
            var observedVideo = null;
            var lastPayload = '';

            function report() {
                var nextVideo = document.querySelector('video');
                if (nextVideo !== observedVideo) {
                    if (observedVideo) {
                        observedVideo.removeEventListener('webkitpresentationmodechanged', report);
                        observedVideo.removeEventListener('webkitbeginfullscreen', report);
                        observedVideo.removeEventListener('webkitendfullscreen', report);
                    }
                    observedVideo = nextVideo;
                    lastPayload = '';
                    if (observedVideo) {
                        observedVideo.addEventListener('webkitpresentationmodechanged', report);
                        observedVideo.addEventListener('webkitbeginfullscreen', report);
                        observedVideo.addEventListener('webkitendfullscreen', report);
                    }
                }

                var supportsPiP = false;
                var supportsFullscreen = false;
                var mode = 'unknown';
                if (observedVideo) {
                    mode = observedVideo.webkitPresentationMode || 'inline';
                    try {
                        supportsPiP = typeof observedVideo.webkitSupportsPresentationMode === 'function'
                            && observedVideo.webkitSupportsPresentationMode('picture-in-picture');
                    } catch (e) {
                        supportsPiP = false;
                    }
                    supportsFullscreen = typeof observedVideo.webkitEnterFullscreen === 'function';
                }
                var payload = {
                    hasVideo: !!observedVideo,
                    mode: mode,
                    supportsPiP: !!supportsPiP,
                    supportsFullscreen: !!supportsFullscreen
                };
                var serialised = JSON.stringify(payload);
                if (serialised === lastPayload) return;
                lastPayload = serialised;
                try {
                    window.webkit.messageHandlers.uxYouTubePiP.postMessage(payload);
                } catch (e) { /* The native handler may be unavailable during teardown. */ }
            }

            report();
            setInterval(report, 1000);
        })();
        """
        let pictureInPictureScript = WKUserScript(
            source: pictureInPictureSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: Self.pictureInPictureContentWorld
        )
        webView.configuration.userContentController.addUserScript(pictureInPictureScript)
    }

    /// Loads the loopback embed page for `videoID`, starting the shared loopback server first if
    /// this is the first video played this session. A web view without a window is parked before
    /// returning so playback can start from the Library or mini player without opening Now Playing.
    func load(videoID: String, lowQuality: Bool = false) async throws {
        if pictureInPictureMode == .pictureInPicture {
            await exitPictureInPicture()
        }
        if pictureInPictureMode == .fullscreen {
            await exitFullscreen()
        }
        resetPictureInPictureState()
        if preferredLowQuality != lowQuality {
            setLowQuality(lowQuality)
        }
        appliedLowQuality = isLowQuality
        let port = try await YouTubeEmbedLoopbackServer.shared.ensureStarted()
        guard let url = YouTubeEmbedPlayer.loopbackPageURL(
            port: Int(port),
            videoID: videoID,
            lowQuality: isLowQuality
        ) else {
            throw YouTubeEmbedPlayer.EmbedPlayerError.invalidVideoID
        }
        webView.load(URLRequest(url: url))
        if webView.window == nil {
            park()
        }
    }

    /// Requests PiP on the YouTube iframe's own frame. The mode-change event is the success
    /// signal because WebKit may accept the JavaScript request before the system PiP window opens;
    /// see `mobile_youtube_background_research/notes/background-pause.md` §B-4.
    func enterPictureInPicture() async -> Bool {
        guard isPictureInPictureAvailable, let frame = pictureInPictureFrame else { return false }
        if pictureInPictureMode == .pictureInPicture { return true }
        guard pictureInPictureEnterContinuation == nil else { return false }

        let script = """
        (function () {
            var v = document.querySelector('video');
            if (!v || v.disablePictureInPicture || typeof v.webkitSetPresentationMode !== 'function') {
                return false;
            }
            try {
                v.webkitSetPresentationMode('picture-in-picture');
                return true;
            } catch (e) {
                return false;
            }
        })()
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: frame,
                contentWorld: Self.pictureInPictureContentWorld
            )
            NSLog("[UXM_YT_PIP] PiP JS request result=%@", String(describing: result))
        } catch {
            NSLog("[UXM_YT_PIP] PiP JS request error=%@", String(describing: error))
        }

        if pictureInPictureMode == .pictureInPicture { return true }
        return await waitForPictureInPictureMode()
    }

    /// Requests native fullscreen on the YouTube iframe's own frame. The mode-change event is the
    /// success signal; see `mobile_youtube_background_research/notes/background-pause.md` §C-1.
    func enterFullscreen() async -> Bool {
        guard isFullscreenAvailable, let frame = pictureInPictureFrame else { return false }
        if pictureInPictureMode == .fullscreen { return true }
        guard fullscreenEnterContinuation == nil else { return false }

        let script = """
        (function () {
            var v = document.querySelector('video');
            if (!v || typeof v.webkitEnterFullscreen !== 'function') return false;
            try {
                v.webkitEnterFullscreen();
                return true;
            } catch (e) {
                return false;
            }
        })()
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: frame,
                contentWorld: Self.pictureInPictureContentWorld
            )
            NSLog("[UXM_YT_PIP] fullscreen JS request result=%@", String(describing: result))
        } catch {
            NSLog("[UXM_YT_PIP] fullscreen JS request error=%@", String(describing: error))
        }

        if pictureInPictureMode == .fullscreen { return true }
        return await waitForFullscreenMode()
    }

    /// Requests the iframe video to return to inline presentation.
    func exitPictureInPicture() async {
        guard let frame = pictureInPictureFrame else { return }
        let script = """
        (function () {
            var v = document.querySelector('video');
            if (!v || typeof v.webkitSetPresentationMode !== 'function') return false;
            try {
                v.webkitSetPresentationMode('inline');
                return true;
            } catch (e) {
                return false;
            }
        })()
        """
        _ = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: frame,
            contentWorld: Self.pictureInPictureContentWorld
        )
    }

    /// Requests the iframe video to leave native fullscreen and return inline.
    func exitFullscreen() async {
        guard let frame = pictureInPictureFrame else { return }
        let script = """
        (function () {
            var v = document.querySelector('video');
            if (!v) return false;
            try {
                if (typeof v.webkitExitFullscreen === 'function') {
                    v.webkitExitFullscreen();
                    return true;
                }
            } catch (e) { /* Fall through to the presentation-mode API. */ }
            try {
                if (typeof v.webkitSetPresentationMode === 'function') {
                    v.webkitSetPresentationMode('inline');
                    return true;
                }
            } catch (e) { /* Ignore an already-ended fullscreen transition. */ }
            return false;
        })()
        """
        _ = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: frame,
            contentWorld: Self.pictureInPictureContentWorld
        )
    }

    /// Applies the low-quality player-size policy to the current web view location and the page.
    func setLowQuality(_ enabled: Bool) {
        preferredLowQuality = enabled
        refreshEffectiveQuality()
        if let superview = webView.superview {
            layoutWebView(in: superview)
        }
    }

    /// Re-evaluates the effective quality and tells the page only when it actually changed.
    private func refreshEffectiveQuality() {
        let effective = isLowQuality
        guard effective != appliedLowQuality else { return }
        appliedLowQuality = effective
        send(.setLowQuality(effective))
    }

    /// Lays out the web view with native sizing. The page must not see a CSS scale-up: simulator
    /// measurements show YouTube includes CSS transforms in its quality measurement, while this
    /// native 256x144-physical-pixel target reaches the approximately 360p floor.
    func layoutWebView(in container: UIView) {
        guard webView.superview === container else { return }
        refreshEffectiveQuality()

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.transform = .identity
        guard isLowQuality else {
            webView.frame = container.bounds
            return
        }

        let screenScale = container.window?.screen.scale ?? UIScreen.main.scale
        let targetSize = CGSize(
            width: Self.lowQualityTargetPixelSize.width / screenScale,
            height: Self.lowQualityTargetPixelSize.height / screenScale
        )
        let scale = max(
            container.bounds.width / targetSize.width,
            container.bounds.height / targetSize.height
        )
        webView.bounds = CGRect(origin: .zero, size: targetSize)
        webView.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Keeps the web view in a visible window hierarchy without displaying it on screen. The
    /// IFrame Player API rejects players that are made too small, so the parking view remains
    /// 256x144 points rather than being reduced to a 1x1 pixel view.
    func park() {
        guard let window = Self.keyWindow() else { return }

        parkingView.translatesAutoresizingMaskIntoConstraints = true
        parkingView.frame = CGRect(x: -256, y: -144, width: 256, height: 144)
        parkingView.alpha = 0.01
        parkingView.isHidden = false
        parkingView.isUserInteractionEnabled = false
        if parkingView.superview !== window || window.subviews.first !== parkingView {
            window.insertSubview(parkingView, at: 0)
        }

        if webView.superview !== parkingView {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = []
            parkingView.addSubview(webView)
        }
        layoutWebView(in: parkingView)
        refreshEffectiveQuality()
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)
    }

    func send(_ command: YouTubeEmbedPlayer.Command) {
        webView.evaluateJavaScript(YouTubeEmbedPlayer.commandScript(command), completionHandler: nil)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "uxYouTube" {
            guard let body = message.body as? [String: Any],
                  let event = YouTubeEmbedPlayer.parseBridgeMessage(body)
            else { return }
            MainActor.assumeIsolated {
                onEvent?(event)
            }
            return
        }

        guard message.name == "uxYouTubePiP",
              let body = message.body as? [String: Any],
              let payload = YouTubeEmbedPlayer.parsePictureInPictureMessage(body)
        else { return }
        let frameInfo = message.frameInfo
        MainActor.assumeIsolated {
            handlePictureInPictureMessage(payload, frameInfo: frameInfo)
        }
    }

    private func resetPictureInPictureState() {
        pictureInPictureFrame = nil
        pictureInPictureSupports = false
        fullscreenSupports = false
        resolvePictureInPictureEnter(false)
        resolveFullscreenEnter(false)
        publishPictureInPictureState(mode: .unknown, available: false, fullscreenAvailable: false)
    }

    private func handlePictureInPictureMessage(
        _ payload: YouTubeEmbedPlayer.PictureInPictureMessage,
        frameInfo: WKFrameInfo
    ) {
        NSLog(
            "[UXM_YT_PIP] report mainFrame=%d hasVideo=%d mode=%@ supportsPiP=%d supportsFullscreen=%d",
            frameInfo.isMainFrame ? 1 : 0,
            payload.hasVideo ? 1 : 0,
            String(describing: payload.mode),
            payload.supportsPiP ? 1 : 0,
            payload.supportsFullscreen ? 1 : 0
        )
        if payload.hasVideo {
            pictureInPictureFrame = frameInfo
            pictureInPictureSupports = payload.supportsPiP
            fullscreenSupports = payload.supportsFullscreen
            publishPictureInPictureState(
                mode: payload.mode,
                available: pictureInPictureFrame != nil
                    && pictureInPictureSupports
                    && AVPictureInPictureController.isPictureInPictureSupported(),
                fullscreenAvailable: pictureInPictureFrame != nil && fullscreenSupports
            )
            return
        }

        // A top-level document can report no video before the late-created YouTube iframe does.
        // Do not discard a known iframe frame because of that unrelated report. A no-video report
        // from the known frame, however, invalidates that frame and its capabilities.
        if let knownFrame = pictureInPictureFrame {
            guard knownFrame.isEqual(frameInfo) else { return }
            pictureInPictureFrame = nil
        }
        pictureInPictureSupports = false
        fullscreenSupports = false
        publishPictureInPictureState(mode: .unknown, available: false, fullscreenAvailable: false)
    }

    private func publishPictureInPictureState(
        mode: YouTubeEmbedPlayer.PresentationMode,
        available: Bool,
        fullscreenAvailable: Bool
    ) {
        let modeChanged = pictureInPictureMode != mode
        let availabilityChanged = isPictureInPictureAvailable != available
        let fullscreenAvailabilityChanged = isFullscreenAvailable != fullscreenAvailable
        pictureInPictureMode = mode
        isPictureInPictureAvailable = available
        isFullscreenAvailable = fullscreenAvailable
        if mode == .pictureInPicture {
            resolvePictureInPictureEnter(true)
        }
        if mode == .fullscreen {
            resolveFullscreenEnter(true)
        }
        if modeChanged {
            refreshEffectiveQuality()
            if let superview = webView.superview { layoutWebView(in: superview) }
        }
        if modeChanged || availabilityChanged || fullscreenAvailabilityChanged {
            onPictureInPictureModeChange?(mode)
        }
    }

    private func waitForPictureInPictureMode() async -> Bool {
        if pictureInPictureMode == .pictureInPicture { return true }
        return await withCheckedContinuation { continuation in
            pictureInPictureEnterContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.resolvePictureInPictureEnter(false)
            }
        }
    }

    private func waitForFullscreenMode() async -> Bool {
        if pictureInPictureMode == .fullscreen { return true }
        return await withCheckedContinuation { continuation in
            fullscreenEnterContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.resolveFullscreenEnter(false)
            }
        }
    }

    private func resolvePictureInPictureEnter(_ entered: Bool) {
        guard let continuation = pictureInPictureEnterContinuation else { return }
        pictureInPictureEnterContinuation = nil
        continuation.resume(returning: entered)
    }

    private func resolveFullscreenEnter(_ entered: Bool) {
        guard let continuation = fullscreenEnterContinuation else { return }
        fullscreenEnterContinuation = nil
        continuation.resume(returning: entered)
    }
}
