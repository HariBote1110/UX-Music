package server

import (
	"net/http"
	"strings"

	"ux-music-sidecar/internal/youtube"
)

// remoteYouTubeResolveHandler serves `GET /v1/remote/youtube/resolve?url=…`.
//
// デスクトップ版に YouTube「検索」機能は存在しない（URL 貼り付けによる
// 追加のみ）。そのため iPhone 側もデスクトップと同じ体験（YouTube の
// URL を貼り付けて動画情報を取得する）を LAN 経由で提供する。取得した
// videoId は iPhone 側の WKWebView 公式埋め込みプレイヤーへそのまま渡す。
func remoteYouTubeResolveHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	rawURL := strings.TrimSpace(r.URL.Query().Get("url"))
	if rawURL == "" {
		writeAPIError(w, "missing url", http.StatusBadRequest)
		return
	}
	info, err := youtube.GetYouTubeVideoInfo(rawURL)
	if err != nil || info == nil {
		writeAPIError(w, "invalid or unresolvable YouTube url", http.StatusBadRequest)
		return
	}
	writeJSON(w, buildYouTubeResolveResponse(info))
}

// buildYouTubeResolveResponse は internal/youtube の動画情報を、iPhone の
// 公式埋め込みプレイヤーが必要とする最小限の JSON へ変換する。
func buildYouTubeResolveResponse(info *youtube.YouTubeVideoInfo) map[string]interface{} {
	return map[string]interface{}{
		"videoId":   info.ID,
		"title":     info.Title,
		"author":    info.Author,
		"duration":  info.Duration,
		"thumbnail": info.Thumbnail,
	}
}
