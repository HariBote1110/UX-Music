package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
)

// TestRemoteSituationPlaylistsHandler_ReturnsFixedOrderWithSongIDs は、
// /v1/remote/situation-playlists がライブラリの id を songIds として、
// 固定順序（最近追加した曲→よく聴く曲→ランダムピック）で返すことを検証する。
func TestRemoteSituationPlaylistsHandler_ReturnsFixedOrderWithSongIDs(t *testing.T) {
	newTempUserDataStore(t)

	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "song-a", "path": "/x/a.flac"},
		{"id": "song-b", "path": "/x/b.flac"},
		{"id": "song-c", "path": "/x/c.flac"},
	}); err != nil {
		t.Fatalf("save library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		"/x/b.flac": map[string]interface{}{"count": float64(5)},
	}); err != nil {
		t.Fatalf("save playcounts: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/situation-playlists", nil)
	rec := httptest.NewRecorder()
	remoteSituationPlaylistsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	var got []map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	// Library has only 3 songs (< 5), so "ランダムピック" is empty and omitted.
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2; body = %s", len(got), rec.Body.String())
	}
	if got[0]["name"] != "最近追加した曲" {
		t.Fatalf("entry[0].name = %v", got[0]["name"])
	}
	if got[1]["name"] != "よく聴く曲" {
		t.Fatalf("entry[1].name = %v", got[1]["name"])
	}
	mostPlayedIDs, ok := got[1]["songIds"].([]interface{})
	if !ok || len(mostPlayedIDs) != 1 || mostPlayedIDs[0] != "song-b" {
		t.Fatalf("entry[1].songIds = %v", got[1]["songIds"])
	}
}

// TestRemoteSituationPlaylistsHandler_EmptyLibraryReturnsEmptyArray は、
// ライブラリが空でもエラーではなく `[]` を返すことを検証する。
func TestRemoteSituationPlaylistsHandler_EmptyLibraryReturnsEmptyArray(t *testing.T) {
	newTempUserDataStore(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/situation-playlists", nil)
	rec := httptest.NewRecorder()
	remoteSituationPlaylistsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	var got []interface{}
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0; body = %s", len(got), body)
	}
}

// TestRemoteSituationPlaylistsHandler_RejectsNonGET は、POST 等が 405 を
// 返すことを兄弟ハンドラ（remotePlaylistsHandler 等）と揃えて検証する。
func TestRemoteSituationPlaylistsHandler_RejectsNonGET(t *testing.T) {
	newTempUserDataStore(t)

	req := httptest.NewRequest(http.MethodPost, "/v1/remote/situation-playlists", nil)
	rec := httptest.NewRecorder()
	remoteSituationPlaylistsHandler(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rec.Code)
	}
}
