package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
)

// newRemoteCommandTestApp は /v1/remote/command 用のテストアプリを用意する。
// playCountsEmitter を差し込み、emit されたイベントを観測できるようにする。
func newRemoteCommandTestApp(t *testing.T) (*App, *[]struct {
	name string
	data interface{}
}) {
	t.Helper()
	emitted := &[]struct {
		name string
		data interface{}
	}{}
	app := &App{
		ctx: context.Background(),
		playCountsEmitter: func(_ context.Context, name string, data interface{}) {
			*emitted = append(*emitted, struct {
				name string
				data interface{}
			}{name: name, data: data})
		},
	}
	return app, emitted
}

func seedRemoteCommandLibrarySong(t *testing.T, id, path, title, artist string) {
	t.Helper()
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": id, "path": path, "title": title, "artist": artist, "duration": float64(200)},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
}

func TestRemoteCommandPlaySongHeadlessModeReturnsGUIRequiredError(t *testing.T) {
	newTempRemoteStore(t)
	seedRemoteCommandLibrarySong(t, "trk-1", "/music/trk-1.flac", "Song One", "Artist One")
	token := ensureDeviceAuthToken("dev_appletv")
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeHeadless)

	app, emitted := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"play-song","songId":"trk-1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code < 400 {
		t.Fatalf("expected an error status in headless mode, got %d: %s", rec.Code, rec.Body.String())
	}
	var errBody apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &errBody); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if errBody.Error.Code != "gui_required" {
		t.Fatalf("expected gui_required error code, got %#v", errBody)
	}
	if len(*emitted) != 0 {
		t.Fatalf("expected no emit in headless mode, got %#v", *emitted)
	}
}

func TestRemoteCommandPlaySongUnknownSongReturnsNotFound(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeGUI)

	app, _ := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"play-song","songId":"does-not-exist"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unknown songId, got %d: %s", rec.Code, rec.Body.String())
	}
	var errBody apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &errBody); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if errBody.Error.Code != "not_found" {
		t.Fatalf("expected not_found error code, got %#v", errBody)
	}
}

func TestRemoteCommandPlaySongMissingSongIDReturnsBadRequest(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeGUI)

	app, _ := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"play-song"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing songId, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemoteCommandPlaySongHappyPathEmitsEvent(t *testing.T) {
	newTempRemoteStore(t)
	seedRemoteCommandLibrarySong(t, "trk-1", "/music/trk-1.flac", "Song One", "Artist One")
	token := ensureDeviceAuthToken("dev_appletv")
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeGUI)

	app, emitted := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"play-song","songId":"trk-1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if len(*emitted) != 1 {
		t.Fatalf("expected exactly one emit, got %#v", *emitted)
	}
	if (*emitted)[0].name != "remote-play-song" {
		t.Fatalf("expected remote-play-song event, got %#v", (*emitted)[0])
	}
	songID, ok := (*emitted)[0].data.(string)
	if !ok || songID != "trk-1" {
		t.Fatalf("expected songId payload trk-1, got %#v", (*emitted)[0].data)
	}
}
