import Foundation

/// Pure logic for the YouTube official embed player (WKWebView + IFrame Player API).
///
/// Mirrors `server/embed_host.go` from the desktop app, adapted for iOS. On desktop, the
/// player page is served from a `127.0.0.1` loopback HTTP host so the page's origin is a
/// valid `http://` origin (otherwise YouTube rejects the embed with error 153, "Referer
/// missing"). On iOS there is no long-running local HTTP server; instead the HTML is loaded
/// via `WKWebView.loadHTMLString(_:baseURL:)` with `baseURL = http://127.0.0.1`, which sets
/// the page's `document.location`/`origin` to that value without an actual server needing to
/// answer requests on that port. This is the standard mobile workaround for IFrame API error
/// 153 and avoids the complexity of a `WKURLSchemeHandler` (a custom scheme such as
/// `ux-embed://` is not an `http`/`https` origin, so YouTube would still refuse it).
enum YouTubeEmbedPlayer {
    private static let videoIDPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")

    private static func isValidVideoID(_ videoID: String) -> Bool {
        let range = NSRange(videoID.startIndex..<videoID.endIndex, in: videoID)
        return videoIDPattern.firstMatch(in: videoID, range: range) != nil
    }

    enum EmbedPlayerError: Error, Equatable {
        case invalidVideoID
    }

    enum PlayerState: Equatable {
        case unstarted
        case ended
        case playing
        case paused
        case buffering
        case cued
        case unknown(Int)

        init(rawState: Int) {
            switch rawState {
            case -1: self = .unstarted
            case 0: self = .ended
            case 1: self = .playing
            case 2: self = .paused
            case 3: self = .buffering
            case 5: self = .cued
            default: self = .unknown(rawState)
            }
        }
    }

    enum BridgeEvent: Equatable {
        case ready
        case state(PlayerState)
        case time(current: Double, duration: Double)
        case error(code: Int)
    }

    enum Command: Equatable {
        case play
        case pause
        case seek(seconds: Double)
        case unmute
    }

    /// Validates a YouTube video ID (always 11 characters of `[A-Za-z0-9_-]`, matching
    /// `embedVideoIDPattern` in `server/embed_host.go`) and builds the host page HTML.
    static func buildEmbedHTML(videoID: String) throws -> String {
        guard isValidVideoID(videoID) else {
            throw EmbedPlayerError.invalidVideoID
        }
        return embedPageTemplate.replacingOccurrences(of: "__VIDEO_ID__", with: videoID)
    }

    /// URL for the app-local loopback HTTP host (`YouTubeEmbedLoopbackServer`) serving the embed
    /// page for `videoID` on `port`. Mirrors `embedHostPageURL` in `server/embed_host.go`. Returns
    /// `nil` for an invalid video ID instead of throwing, since callers building a URL to hand to
    /// `WKWebView.load(_:)` have no natural place to surface a thrown error.
    static func loopbackPageURL(port: Int, videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/embed"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    /// Japanese user-facing message for an IFrame Player API `onError` code. Codes per the
    /// official docs: 2 = invalid parameter, 5 = HTML5 player error, 100 = video not
    /// found/removed, 101/150 = embedding disallowed by the video owner.
    static func errorMessage(code: Int) -> String {
        switch code {
        case -1:
            return "再生用のローカルサーバーを起動できませんでした。アプリを再起動してお試しください。"
        case 2:
            return "動画を再生できませんでした（不正なパラメータ）。"
        case 5:
            return "動画を再生できませんでした（プレイヤーエラー）。"
        case 100:
            return "この動画は見つかりませんでした（削除または非公開の可能性があります）。"
        case 101, 150:
            return "この動画は投稿者により埋め込み再生が許可されていません。YouTubeアプリでご視聴ください。"
        default:
            return "動画の再生中にエラーが発生しました（コード: \(code)）。"
        }
    }

    /// How the UI should recover from an `onError` code. `.openInYouTubeApp` covers 101/150
    /// ("embedding disallowed") — see `progress/mobile-youtube-embed.md` (フェーズC): this is a
    /// genuine server-side YouTube restriction on mobile-web embedding, reproducible in real
    /// mobile Safari, so no in-app playback retry can recover it. The only path back to the video
    /// itself is the official YouTube app (or its website), which still counts the view and pays
    /// out to the creator normally. Other codes (invalid parameter, HTML5 player error, video not
    /// found, local loopback-server start failure) get no fallback action — those are either
    /// transient or mean the video is genuinely gone.
    enum EmbedFallback: Equatable {
        case none
        case openInYouTubeApp
    }

    static func embedFallback(forErrorCode code: Int) -> EmbedFallback {
        switch code {
        case 101, 150:
            return .openInYouTubeApp
        default:
            return .none
        }
    }

    /// `youtube://` deep link that opens `videoID` directly in the official YouTube app, if
    /// installed. `nil` for an invalid video ID.
    static func youtubeAppDeepLinkURL(videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        return URL(string: "youtube://watch?v=\(videoID)")
    }

    /// `https://www.youtube.com/watch?v=<id>` fallback for when the YouTube app is not installed
    /// (opened in Safari instead). `nil` for an invalid video ID.
    static func youtubeWebFallbackURL(videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    /// Picks which of the two above to actually open. `youtubeAppIsAvailable` is the caller's
    /// `UIApplication.shared.canOpenURL(_:)` check against the app's URL scheme — kept as a plain
    /// `Bool` parameter (rather than calling `UIApplication` here) so this selection logic stays a
    /// pure, unit-testable function.
    static func urlToOpen(forVideoID videoID: String, youtubeAppIsAvailable: Bool) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        if youtubeAppIsAvailable, let appURL = youtubeAppDeepLinkURL(videoID: videoID) {
            return appURL
        }
        return youtubeWebFallbackURL(videoID: videoID)
    }

    /// Decodes a `window.webkit.messageHandlers.uxYouTube.postMessage(...)` payload sent by the
    /// page's JS bridge into a typed event. Returns `nil` for unrecognised or malformed payloads.
    static func parseBridgeMessage(_ body: [String: Any]) -> BridgeEvent? {
        guard let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "state":
            guard let raw = (body["state"] as? Int) ?? (body["state"] as? NSNumber)?.intValue else { return nil }
            return .state(PlayerState(rawState: raw))
        case "time":
            guard let current = numberValue(body["currentTime"]), let duration = numberValue(body["duration"]) else {
                return nil
            }
            return .time(current: current, duration: duration)
        case "error":
            guard let code = (body["code"] as? Int) ?? (body["code"] as? NSNumber)?.intValue else { return nil }
            return .error(code: code)
        default:
            return nil
        }
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Builds the JS snippet evaluated on the WKWebView to drive the embedded player.
    static func commandScript(_ command: Command) -> String {
        switch command {
        case .play:
            return "window.uxYouTubeCommand({cmd:'play'});"
        case .pause:
            return "window.uxYouTubeCommand({cmd:'pause'});"
        case .seek(let seconds):
            return "window.uxYouTubeCommand({cmd:'seek', seconds:\(seconds)});"
        case .unmute:
            return "window.uxYouTubeCommand({cmd:'unmute'});"
        }
    }

    /// Host page HTML. Structurally mirrors `embedPageTemplate` in `server/embed_host.go`
    /// (including the mute-then-unmute autoplay sequence), and relays bridge events via
    /// `window.postMessage` exactly like desktop's `parent.postMessage`/`addEventListener` pair —
    /// deliberately *not* by calling `window.webkit.messageHandlers` directly from this script. The
    /// native `uxYouTube` handler is registered in an isolated `WKContentWorld`
    /// (`YouTubePlaybackHost.bridgeContentWorld`) so `window.webkit.messageHandlers` is absent from
    /// this `.page`-world script (and from the nested `youtube.com/embed` iframe's own `.page`
    /// world), keeping the native bridge's exposure to a minimum — see the comment in
    /// `YouTubePlaybackHost.init()`. (Note: this isolation does *not* fix IFrame Player API error
    /// 150 for videos blocked on mobile — that turned out to be a genuine YouTube-side mobile-web
    /// embedding restriction, reproducible in real mobile Safari; see
    /// `progress/mobile-youtube-embed.md`.) A `WKUserScript` relay running in that isolated world
    /// forwards this frame's `postMessage` traffic to the native handler. `window.uxYouTubeCommand`
    /// (called from Swift via `evaluateJavaScript`, not from the isolated world) is unaffected since
    /// `evaluateJavaScript` runs in the `.page` world by default.
    private static let embedPageTemplate = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{width:100%;height:100%}</style>
    </head>
    <body>
    <div id="player"></div>
    <script>
    (function () {
        'use strict';
        var VIDEO_ID = '__VIDEO_ID__';
        var player = null;
        var timer = null;

        function post(msg) {
            msg.source = 'ux-embed';
            try { window.postMessage(msg, '*'); } catch (e) { /* ignore */ }
        }

        function startTimer() {
            if (timer) return;
            timer = setInterval(function () {
                if (!player || typeof player.getCurrentTime !== 'function') return;
                try {
                    post({
                        type: 'time',
                        currentTime: player.getCurrentTime() || 0,
                        duration: player.getDuration() || 0
                    });
                } catch (e) { /* ignore */ }
            }, 250);
        }

        window.onYouTubeIframeAPIReady = function () {
            player = new YT.Player('player', {
                width: '100%',
                height: '100%',
                videoId: VIDEO_ID,
                playerVars: {
                    autoplay: 1,
                    mute: 1,
                    playsinline: 1,
                    controls: 1,
                    enablejsapi: 1,
                    rel: 0,
                    origin: location.origin
                },
                events: {
                    onReady: function () {
                        try { player.mute(); } catch (e) { /* ignore */ }
                        post({ type: 'ready' });
                        startTimer();
                    },
                    onStateChange: function (e) { post({ type: 'state', state: e.data }); },
                    onError: function (e) { post({ type: 'error', code: e.data }); }
                }
            });
        };

        window.uxYouTubeCommand = function (d) {
            if (!player) return;
            try {
                if (d.cmd === 'play') player.playVideo();
                else if (d.cmd === 'pause') player.pauseVideo();
                else if (d.cmd === 'seek') player.seekTo(Math.max(0, Number(d.seconds) || 0), true);
                else if (d.cmd === 'unmute') { player.unMute(); player.setVolume(100); }
            } catch (e) { /* ignore */ }
        };

        var s = document.createElement('script');
        s.src = 'https://www.youtube.com/iframe_api';
        document.head.appendChild(s);
    })();
    </script>
    </body>
    </html>
    """
}
