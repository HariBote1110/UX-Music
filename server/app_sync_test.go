package server

import (
	"bytes"
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
