package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
)

// TestRemoteSongsHandler_HasLocalAudioField は /v1/remote/songs のレスポンスに
// 追加された hasLocalAudio フィールドが、ローカルファイルを持つ曲では true、
// ダウンロードせず埋め込み再生のみで登録された YouTube 曲 (type: "youtube")
// では false になることを検証する。
func TestRemoteSongsHandler_HasLocalAudioField(t *testing.T) {
	newTempRemoteStore(t)
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "local-1", "path": "/music/local-1.flac", "title": "Local Song", "type": "local"},
		{"id": "legacy-1", "path": "/music/legacy-1.flac", "title": "Legacy Song"}, // type 未設定 = ローカル扱い
		{"id": "yt-1", "path": "https://www.youtube.com/watch?v=abc123", "title": "Embed-only Song", "type": "youtube"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	rec := httptest.NewRecorder()
	remoteSongsHandler(rec, req)

	var songs []map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &songs); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(songs) != 3 {
		t.Fatalf("expected 3 songs, got %d", len(songs))
	}

	got := make(map[string]interface{}, len(songs))
	for _, s := range songs {
		got[s["id"].(string)] = s["hasLocalAudio"]
	}

	if v, ok := got["local-1"].(bool); !ok || !v {
		t.Fatalf("local-1 hasLocalAudio = %#v, want true", got["local-1"])
	}
	if v, ok := got["legacy-1"].(bool); !ok || !v {
		t.Fatalf("legacy-1 hasLocalAudio = %#v, want true", got["legacy-1"])
	}
	if v, ok := got["yt-1"].(bool); !ok || v {
		t.Fatalf("yt-1 hasLocalAudio = %#v, want false", got["yt-1"])
	}
}

// TestRemoteFileHandler_EmbedOnlySongReturnsClean404 は type:"youtube" な
// (ダウンロードされていない) 曲を /v1/remote/file/{id} で要求した場合、生の
// ファイルシステムエラーではなく明確なエラーコード付き 404 が返ることを
// 検証する。
func TestRemoteFileHandler_EmbedOnlySongReturnsClean404(t *testing.T) {
	newTempRemoteStore(t)
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "yt-1", "path": "https://www.youtube.com/watch?v=abc123", "title": "Embed-only Song", "type": "youtube"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/file/yt-1", nil)
	rec := httptest.NewRecorder()
	remoteFileHandler(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	var errBody apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &errBody); err != nil {
		t.Fatalf("decode error body: %v (body=%s)", err, rec.Body.String())
	}
	if errBody.Error.Code != "no_local_audio" {
		t.Fatalf("error code = %q, want %q", errBody.Error.Code, "no_local_audio")
	}
}
