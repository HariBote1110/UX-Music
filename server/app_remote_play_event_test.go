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

// newRemotePlayEventTestApp は /v1/remote/play-event 用のテストアプリを用意する。
// playCountsEmitter を差し込み、emit された play-counts-updated を観測できるようにする。
func newRemotePlayEventTestApp(t *testing.T) (*App, *[]struct {
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

func seedRemotePlayEventLibrarySong(t *testing.T, id, path, title, artist string) {
	t.Helper()
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": id, "path": path, "title": title, "artist": artist, "duration": float64(200)},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
}

func TestRemotePlayEventRequiresDeviceAuth(t *testing.T) {
	newTempRemoteStore(t)
	seedRemotePlayEventLibrarySong(t, "trk-1", "/music/trk-1.flac", "Song One", "Artist One")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"trackId":"trk-1","playedAt":"2026-06-08T12:00:00Z"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without device token, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemotePlayEventHappyPathAppendsEventAndUpdatesCount(t *testing.T) {
	newTempRemoteStore(t)
	seedRemotePlayEventLibrarySong(t, "trk-1", "/music/trk-1.flac", "Song One", "Artist One")
	token := ensureDeviceAuthToken("dev_appletv")
	app, emitted := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"trackId":"trk-1","playedAt":"2026-06-08T12:00:00Z","durationPlayedSec":210}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var resp remotePlayEventResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.TrackID != "trk-1" {
		t.Fatalf("expected trackId echoed back, got %#v", resp)
	}
	if resp.MatchKey == "" {
		t.Fatalf("expected non-empty matchKey, got %#v", resp)
	}
	if resp.Count != 1 {
		t.Fatalf("expected count 1 after single play report, got %#v", resp)
	}

	events := readStoredSyncPlayEvents(t)
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 stored play event, got %d", len(events))
	}
	if events[0].TrackID != "trk-1" || !events[0].Completed {
		t.Fatalf("unexpected stored event: %#v", events[0])
	}

	if len(*emitted) != 1 || (*emitted)[0].name != "play-counts-updated" {
		t.Fatalf("expected one play-counts-updated emit, got %#v", *emitted)
	}
}

func TestRemotePlayEventUnknownTrackReturnsNotFound(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"trackId":"does-not-exist","playedAt":"2026-06-08T12:00:00Z"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unknown trackId, got %d: %s", rec.Code, rec.Body.String())
	}
	var errBody apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &errBody); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if errBody.Error.Code != "not_found" {
		t.Fatalf("expected not_found error code, got %#v", errBody)
	}
}

func TestRemotePlayEventMalformedBodyReturnsBadRequest(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader([]byte("{not json")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for malformed JSON, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemotePlayEventMissingTrackIDReturnsBadRequest(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"playedAt":"2026-06-08T12:00:00Z"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing trackId, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemotePlayEventRejectsWrongMethod(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/play-event", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 for GET, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemotePlayEventDuplicateDeliveryIsIdempotent(t *testing.T) {
	newTempRemoteStore(t)
	seedRemotePlayEventLibrarySong(t, "trk-1", "/music/trk-1.flac", "Song One", "Artist One")
	token := ensureDeviceAuthToken("dev_appletv")
	app, _ := newRemotePlayEventTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"trackId":"trk-1","playedAt":"2026-06-08T12:00:00Z","durationPlayedSec":210}`)

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/v1/remote/play-event", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("delivery %d: unexpected status %d: %s", i, rec.Code, rec.Body.String())
		}
	}

	events := readStoredSyncPlayEvents(t)
	if len(events) != 1 {
		t.Fatalf("expected duplicate delivery to be deduplicated to 1 event, got %d", len(events))
	}

	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts["/music/trk-1.flac"].(map[string]interface{})
	if entry == nil || entry["count"] != float64(1) {
		t.Fatalf("expected count to stay at 1 after duplicate delivery, got %#v", counts)
	}
}
