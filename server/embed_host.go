package server

// YouTube 公式再生（embed）用のループバック HTTP ホスト。
//
// Wails のページは wails:// という独自スキームで配信されるため、
// そこから直接 IFrame Player API を使うと YouTube 側へ有効な
// HTTP Referer / origin が渡らず、エラー 153（Referer 欠落による
// 埋め込み再生拒否）になる。このホストは 127.0.0.1 のみで待ち受ける
// 小さな HTTP サーバーで、公式プレイヤーを載せたページを配信する。
// ページの origin が http://127.0.0.1:<port> という正当な HTTP origin に
// なるため、YouTube が埋め込みを受け入れる。親（アプリ本体）とは
// postMessage で制御・状態を中継する。

import (
	"fmt"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
)

var embedVideoIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)

// embedPageTemplate は __VIDEO_ID__ を検証済みの動画 ID で置換して使う。
// 親ウィンドウとのプロトコル:
//   - ページ → 親: {source:'ux-embed', type:'ready'|'state'|'error'|'time', ...}
//   - 親 → ページ: {source:'ux-embed-cmd', cmd:'play'|'pause'|'seek', seconds}
const embedPageTemplate = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>UX Music - YouTube Embed Host</title>
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
        try { parent.postMessage(msg, '*'); } catch (e) { /* ignore */ }
    }

    function startTimer() {
        if (timer) return;
        timer = setInterval(function () {
            if (!player || typeof player.getCurrentTime !== 'function') return;
            try {
                post({
                    type: 'time',
                    currentTime: player.getCurrentTime() || 0,
                    duration: player.getDuration() || 0,
                    state: player.getPlayerState()
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
                controls: 1,
                enablejsapi: 1,
                rel: 0,
                playsinline: 1,
                origin: location.origin
            },
            events: {
                onReady: function () { post({ type: 'ready' }); startTimer(); },
                onStateChange: function (e) { post({ type: 'state', state: e.data }); },
                onError: function (e) { post({ type: 'error', code: e.data }); }
            }
        });
    };

    window.addEventListener('message', function (ev) {
        var d = ev.data;
        if (!d || d.source !== 'ux-embed-cmd' || !player) return;
        try {
            if (d.cmd === 'play') player.playVideo();
            else if (d.cmd === 'pause') player.pauseVideo();
            else if (d.cmd === 'seek') player.seekTo(Math.max(0, Number(d.seconds) || 0), true);
        } catch (e) { /* ignore */ }
    });

    var s = document.createElement('script');
    s.src = 'https://www.youtube.com/iframe_api';
    document.head.appendChild(s);
})();
</script>
</body>
</html>
`

// buildEmbedPageHTML は検証済みの動画 ID を埋め込んだホストページを返す。
// ID が 11 文字の YouTube 動画 ID 形式でなければエラー。
func buildEmbedPageHTML(videoID string) (string, error) {
	if !embedVideoIDPattern.MatchString(videoID) {
		return "", fmt.Errorf("invalid YouTube video id: %q", videoID)
	}
	return strings.ReplaceAll(embedPageTemplate, "__VIDEO_ID__", videoID), nil
}

// newEmbedHostHandler は /embed?v=<id> を配信するハンドラーを返す。
func newEmbedHostHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/embed", func(w http.ResponseWriter, r *http.Request) {
		html, err := buildEmbedPageHTML(r.URL.Query().Get("v"))
		if err != nil {
			http.Error(w, "invalid video id", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(html))
	})
	return mux
}

// embedHostPageURL はループバックホスト上の埋め込みページ URL を組み立てる。
func embedHostPageURL(port int, videoID string) string {
	return fmt.Sprintf("http://127.0.0.1:%d/embed?v=%s", port, videoID)
}

var (
	embedHostOnce sync.Once
	embedHostPort int
	embedHostErr  error
)

// startEmbedHost は 127.0.0.1 の空きポートでホストを一度だけ起動する。
func startEmbedHost() (int, error) {
	embedHostOnce.Do(func() {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			embedHostErr = fmt.Errorf("embed host listen: %w", err)
			return
		}
		embedHostPort = listener.Addr().(*net.TCPAddr).Port
		fmt.Printf("[YouTubeEmbedHost] listening on 127.0.0.1:%d\n", embedHostPort)
		go func() {
			_ = http.Serve(listener, newEmbedHostHandler())
		}()
	})
	return embedHostPort, embedHostErr
}

// GetYouTubeEmbedURL は動画 ID を検証し、ループバックホスト上の
// 埋め込みページ URL を返す（ホストは必要時に一度だけ起動）。
func (a *App) GetYouTubeEmbedURL(videoID string) (string, error) {
	if !embedVideoIDPattern.MatchString(videoID) {
		return "", fmt.Errorf("invalid YouTube video id: %q", videoID)
	}
	port, err := startEmbedHost()
	if err != nil {
		return "", err
	}
	return embedHostPageURL(port, videoID), nil
}
