package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/store"
)

// TestRemoteLyricsHandler_ForwardsJaTranslation は、{base}.ja.lrc サイドカーが
// 存在する場合に translationContent / translationFormat がレスポンスへ転送され
// ることを検証する。
func TestRemoteLyricsHandler_ForwardsJaTranslation(t *testing.T) {
	newTempUserDataStore(t)

	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "song1", "title": "TestSong", "path": "/x/TestSong.flac"},
	}); err != nil {
		t.Fatalf("save library: %v", err)
	}

	lyricsDir := lyrics.GetLyricsDir()
	if err := os.WriteFile(filepath.Join(lyricsDir, "TestSong.lrc"), []byte("[00:01.00]Hello\n"), 0o644); err != nil {
		t.Fatalf("write main lyrics: %v", err)
	}
	if err := os.WriteFile(filepath.Join(lyricsDir, "TestSong.ja.lrc"), []byte("[00:01.00]こんにちは\n"), 0o644); err != nil {
		t.Fatalf("write ja lyrics: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/lyrics?id=song1", nil)
	rec := httptest.NewRecorder()
	remoteLyricsHandler(rec, req)

	var got map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got["found"] != true {
		t.Fatalf("found: got %v", got["found"])
	}
	if got["translationContent"] != "[00:01.00]こんにちは\n" {
		t.Fatalf("translationContent: got %v", got["translationContent"])
	}
	if got["translationFormat"] != "lrc" {
		t.Fatalf("translationFormat: got %v", got["translationFormat"])
	}
}

// TestRemoteLyricsHandler_OmitsTranslationKeysWhenAbsent は、和訳サイドカーが
// 無い場合に translationContent / translationFormat キー自体がレスポンスに
// 含まれないこと（空文字列ではなく欠落）を検証する。
func TestRemoteLyricsHandler_OmitsTranslationKeysWhenAbsent(t *testing.T) {
	newTempUserDataStore(t)

	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "song2", "title": "NoTranslationSong", "path": "/x/NoTranslationSong.flac"},
	}); err != nil {
		t.Fatalf("save library: %v", err)
	}

	lyricsDir := lyrics.GetLyricsDir()
	if err := os.WriteFile(filepath.Join(lyricsDir, "NoTranslationSong.lrc"), []byte("[00:01.00]Hello\n"), 0o644); err != nil {
		t.Fatalf("write main lyrics: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/lyrics?id=song2", nil)
	rec := httptest.NewRecorder()
	remoteLyricsHandler(rec, req)

	var got map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if _, ok := got["translationContent"]; ok {
		t.Fatalf("translationContent should be absent, got %v", got["translationContent"])
	}
	if _, ok := got["translationFormat"]; ok {
		t.Fatalf("translationFormat should be absent, got %v", got["translationFormat"])
	}
}

func TestRemotePlaylistPathToSongID(t *testing.T) {
	m := map[string]string{
		"/Music/a.flac":                "song-a",
		"/Volumes/lib/album/track.m4a": "song-b",
	}
	if id, ok := remotePlaylistPathToSongID(m, "/Music/a.flac"); !ok || id != "song-a" {
		t.Fatalf("exact: got %q %v", id, ok)
	}
	// Clean collapses .. so playlist lines remain resolvable.
	if id, ok := remotePlaylistPathToSongID(m, "/Volumes/lib/../lib/album/track.m4a"); !ok || id != "song-b" {
		t.Fatalf("clean: got %q %v", id, ok)
	}
	if _, ok := remotePlaylistPathToSongID(m, "/nope.flac"); ok {
		t.Fatal("expected miss")
	}
}
