package server

import (
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

func TestIncrementPlayCountRecordsLocalSyncPlayEvent(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey: "dev_portable",
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	songPath := filepath.Join(t.TempDir(), "song.flac")
	song := map[string]interface{}{
		"id":                "local-imported-id",
		"syncSourceTrackId": "host-track-1",
		"path":              songPath,
		"title":             "Song",
		"duration":          180.0,
	}

	NewApp().IncrementPlayCount(song)

	events := readStoredSyncPlayEvents(t)
	if len(events) != 1 {
		t.Fatalf("expected one local sync event, got %#v", events)
	}
	if events[0].DeviceID != "dev_portable" || events[0].TrackID != "host-track-1" || !events[0].Completed {
		t.Fatalf("unexpected local sync event: %#v", events[0])
	}
	if events[0].DeviceSequence != 1 || events[0].EventID == "" {
		t.Fatalf("expected stable event identity: %#v", events[0])
	}
}

func TestSyncLibraryEventsAppliesIncomingPlayCountsIdempotently(t *testing.T) {
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
				"eventId": "evt_portable_1",
				"trackId": "host-track-1",
				"deviceId": "dev_portable",
				"deviceSequence": 1,
				"playedAt": "2026-06-09T06:20:00Z",
				"countedAt": "2026-06-09T06:23:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			}
		]
	}`)

	postSyncLibraryEvents(t, payload)
	postSyncLibraryEvents(t, payload)

	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[songPath].(map[string]interface{})
	if entry == nil || entry["count"] != float64(1) {
		t.Fatalf("expected incoming event to increment playcount once, got %#v", counts)
	}
}

func TestAutoSyncPairedDevicesPushesLocalPlayEventsToReachablePeer(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save(syncPlayEventsStoreName, []uxsync.PlayEvent{
		{
			EventID:          "evt_portable_1",
			TrackID:          "host-track-1",
			DeviceID:         "dev_portable",
			DeviceSequence:   1,
			DurationPlayedMs: 180000,
			Completed:        true,
		},
	}); err != nil {
		t.Fatalf("seed sync events: %v", err)
	}

	var observedToken string
	var observedEvents []uxsync.PlayEvent
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion})
		case "/sync/library/events":
			observedToken = r.Header.Get("X-UX-Music-Sync-Token")
			var req syncLibraryEventsRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode events: %v", err)
			}
			observedEvents = req.PlayEvents
			writeJSON(w, syncLibraryEventsResponse{Accepted: len(req.PlayEvents), Ack: uxsync.EventAck{DeviceID: req.DeviceID, MaxDeviceSequence: 1}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed known peer: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.SyncedDevices != 1 || result.PushedPlayEvents != 1 || result.FailedDevices != 0 {
		t.Fatalf("unexpected auto sync result: %#v", result)
	}
	if observedToken != "tok_host" || len(observedEvents) != 1 || observedEvents[0].EventID != "evt_portable_1" {
		t.Fatalf("unexpected pushed token/events token=%q events=%#v", observedToken, observedEvents)
	}
}

func TestAutoSyncPairedDevicesDownloadsMissingArtworkForImportedTrack(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":                 "local-imported-id",
			"path":               filepath.Join(t.TempDir(), "local.mp3"),
			"title":              "Song",
			"artist":             "Artist",
			"album":              "Album",
			"syncSourceDeviceId": "dev_host",
			"syncSourceTrackId":  "remote-track-1",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion})
		case "/sync/assets/remote-track-1/artwork":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="cover.webp"`)
			_, _ = w.Write([]byte("artwork-bytes"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed known peer: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.SyncedArtwork != 1 {
		t.Fatalf("expected one artwork sync, got %#v", result)
	}

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	imported := library[0].(map[string]interface{})
	artwork, _ := imported["artwork"].(map[string]interface{})
	fullName, _ := artwork["full"].(string)
	if fullName == "" {
		t.Fatalf("expected imported track artwork reference, got %#v", imported)
	}
	fullPath := filepath.Join(config.GetUserDataPath(), "Artworks", fullName)
	bytes, err := os.ReadFile(fullPath)
	if err != nil {
		t.Fatalf("read synced artwork: %v", err)
	}
	if string(bytes) != "artwork-bytes" {
		t.Fatalf("unexpected artwork bytes %q", string(bytes))
	}
}
