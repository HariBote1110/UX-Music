package server

import (
	"encoding/json"
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

// remoteYouTubeAddRequest は `POST /v1/remote/youtube/add` のリクエスト本文。
type remoteYouTubeAddRequest struct {
	URL string `json:"url"`
}

// remoteYouTubeAddHandler serves `POST /v1/remote/youtube/add`。
//
// iPhone 側の「YouTube タブ」廃止に伴い、URL 追加導線を Remote ライブラリの
// メニューへ移設する。追加処理はデスクトップと全く同じ App.AddYouTubeLink
// を呼ぶため、デスクトップの再生モード設定（embed/stream/download）に従って
// ライブラリへ登録され、以後は /v1/remote/songs 経由で他の曲と同列に返る。
func (ls *LANServer) remoteYouTubeAddHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	var req remoteYouTubeAddRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	rawURL := strings.TrimSpace(req.URL)
	if rawURL == "" {
		writeAPIError(w, "missing url", http.StatusBadRequest)
		return
	}
	if ls.app == nil {
		writeAPIError(w, "server not ready", http.StatusInternalServerError)
		return
	}

	savedSong, err := ls.app.AddYouTubeLink(rawURL)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, savedSong)
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
