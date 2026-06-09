package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

func newTempSyncStore(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	config.Instance.SetUserDataPath(dir)
	store.Instance = &store.Store{}
}

func TestSyncLibraryEventsPushStoresChildPlayEventsAndReturnsAcks(t *testing.T) {
	newTempSyncStore(t)
	payload := []byte(`{
		"deviceId": "macbook-air",
		"playEvents": [
			{
				"eventId": "evt_air_0001",
				"trackId": "trk_1",
				"deviceId": "macbook-air",
				"deviceSequence": 1,
				"playedAt": "2026-06-08T12:00:00Z",
				"countedAt": "2026-06-08T12:03:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			},
			{
				"eventId": "evt_air_0002",
				"trackId": "trk_1",
				"deviceId": "macbook-air",
				"deviceSequence": 2,
				"playedAt": "2026-06-08T12:10:00Z",
				"countedAt": "2026-06-08T12:13:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			}
		]
	}`)

	first := postSyncLibraryEvents(t, payload)
	second := postSyncLibraryEvents(t, payload)
	events := readStoredSyncPlayEvents(t)
	counts := uxsync.PlayCountsByTrack(events)

	if first.Accepted != 2 || second.Accepted != 2 {
		t.Fatalf("expected both requests to accept 2 events, got first=%d second=%d", first.Accepted, second.Accepted)
	}
	if first.Ack.DeviceID != "macbook-air" || first.Ack.MaxDeviceSequence != 2 {
		t.Fatalf("unexpected ack: %#v", first.Ack)
	}
	if len(events) != 2 {
		t.Fatalf("expected store to keep 2 unique events after resend, got %d", len(events))
	}
	if counts["trk_1"].Count != 2 {
		t.Fatalf("expected 2 counted plays, got %d", counts["trk_1"].Count)
	}
}

func TestSyncLibraryEventsRejectsInvalidMethod(t *testing.T) {
	newTempSyncStore(t)
	req := httptest.NewRequest(http.MethodGet, "/sync/library/events", nil)
	rec := httptest.NewRecorder()

	syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status %d, got %d", http.StatusMethodNotAllowed, rec.Code)
	}
}

func TestSyncLibraryEventsEmitsUpdatedPlayCountsAfterApplyingEvents(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "host.flac")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "host-track-1", "path": songPath, "title": "Host Song"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	payload := []byte(`{
		"deviceId": "dev_portable",
		"playEvents": [
			{
				"eventId": "evt_portable_emit_1",
				"trackId": "host-track-1",
				"deviceId": "dev_portable",
				"deviceSequence": 1,
				"playedAt": "2026-06-09T07:20:00Z",
				"countedAt": "2026-06-09T07:23:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			}
		]
	}`)
	var emitted []struct {
		name string
		data interface{}
	}
	app := &App{
		ctx: context.Background(),
		playCountsEmitter: func(_ context.Context, name string, data interface{}) {
			emitted = append(emitted, struct {
				name string
				data interface{}
			}{name: name, data: data})
		},
	}
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	app.syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if len(emitted) != 1 || emitted[0].name != "play-counts-updated" {
		t.Fatalf("expected one play-counts-updated emit, got %#v", emitted)
	}
	counts, _ := emitted[0].data.(map[string]interface{})
	entry, _ := counts[songPath].(map[string]interface{})
	if entry == nil || entry["count"] != float64(1) {
		t.Fatalf("expected emitted playcounts to include applied count, got %#v", emitted[0].data)
	}
}

func postSyncLibraryEvents(t *testing.T, payload []byte) syncLibraryEventsResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibraryEventsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return response
}

func readStoredSyncPlayEvents(t *testing.T) []uxsync.PlayEvent {
	t.Helper()
	path := filepath.Join(config.Instance.GetUserDataPath(), syncPlayEventsStoreName+".json")
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read sync events store: %v", err)
	}
	var events []uxsync.PlayEvent
	if err := json.Unmarshal(bytes, &events); err != nil {
		t.Fatalf("decode sync events store: %v", err)
	}
	return events
}
