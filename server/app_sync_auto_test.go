package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

func resetImmediatePlaybackSyncStateForTest() {
	immediatePlaybackSyncState.Lock()
	defer immediatePlaybackSyncState.Unlock()
	immediatePlaybackSyncState.running = false
	immediatePlaybackSyncState.pending = false
}

func TestSyncSongMatchKeyNormalisesMetadataAndDuration(t *testing.T) {
	left := syncSongMatchKey(map[string]interface{}{
		"title":    "  Ｓｏｎｇ   Title ",
		"artist":   "ＡＲＴＩＳＴ",
		"album":    " Album ",
		"duration": 179.6,
	})
	right := syncSongMatchKey(map[string]interface{}{
		"title":    "song title",
		"artist":   "artist",
		"album":    "album",
		"duration": 180.4,
	})

	if left == "" || left != right {
		t.Fatalf("expected equivalent metadata to produce the same key, left=%q right=%q", left, right)
	}
}

// syncSongMatchKey はデバイス間で曲を突き合わせるための識別子なので、
// アルゴリズム（正規化 → "artist|album|title|duration" → SHA-1 hex）を
// 変えると既存端末とマッチしなくなる。ゴールデン値をリテラルで固定し、
// 意図しないフォーマット変更を検出する。値を書き換える＝互換性を壊す判断。
func TestSyncSongMatchKeyGoldenValue(t *testing.T) {
	got := syncSongMatchKey(map[string]interface{}{
		"title":    "Song Title",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
	})
	const want = "f38f971e3051520c718c3119a19ebdd535eae04a" // sha1("artist|album|song title|180")
	if got != want {
		t.Fatalf("syncSongMatchKey format changed: got %q want %q", got, want)
	}
}

func TestSyncSongMatchKeyDistinguishesDifferentSongs(t *testing.T) {
	first := syncSongMatchKey(map[string]interface{}{
		"title":    "Song A",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
	})
	second := syncSongMatchKey(map[string]interface{}{
		"title":    "Song B",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
	})

	if first == "" || second == "" || first == second {
		t.Fatalf("expected different songs to produce different keys, first=%q second=%q", first, second)
	}
}

func TestSyncSongMatchKeyIgnoresTransferredFormat(t *testing.T) {
	flac := syncSongMatchKey(map[string]interface{}{
		"title":    "Portable",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 240.0,
		"fileType": ".flac",
	})
	mp3 := syncSongMatchKey(map[string]interface{}{
		"title":                "portable",
		"artist":               "artist",
		"album":                "album",
		"duration":             240.0,
		"fileType":             ".mp3",
		"syncTransferEncoding": syncTransferEncodingMP3320,
		"audioBitrateKbps":     320,
	})

	if flac == "" || flac != mp3 {
		t.Fatalf("expected format-independent match keys, flac=%q mp3=%q", flac, mp3)
	}
}

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
	if events[0].MatchKey == "" {
		t.Fatalf("expected local sync event to include match key: %#v", events[0])
	}
}

func TestIncrementPlayCountTriggersImmediateSyncWhenPeerReachable(t *testing.T) {
	newTempSyncStore(t)
	resetImmediatePlaybackSyncStateForTest()
	songPath := filepath.Join(t.TempDir(), "portable.flac")
	if err := os.WriteFile(songPath, []byte("audio"), 0o644); err != nil {
		t.Fatalf("write audio: %v", err)
	}
	song := map[string]interface{}{
		"id":                "local-imported-id",
		"syncSourceTrackId": "host-track-1",
		"path":              songPath,
		"title":             "Portable Song",
		"artist":            "Artist",
		"album":             "Album",
		"duration":          180.0,
	}
	received := make(chan []uxsync.PlayEvent, 1)
	observer := &handlerObserver{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion})
		case "/sync/library/events":
			var req syncLibraryEventsRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				observer.errorf("decode events: %v", err)
				http.Error(w, "bad events payload", http.StatusBadRequest)
				return
			}
			received <- req.PlayEvents
			writeJSON(w, syncLibraryEventsResponse{
				Accepted: len(req.PlayEvents),
				Ack:      uxsync.EventAck{DeviceID: req.DeviceID, MaxDeviceSequence: 1, AckedEventIDs: eventIDs(req.PlayEvents)},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_air",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	NewApp().IncrementPlayCount(song)

	select {
	case events := <-received:
		observer.assertNoErrors(t)
		if len(events) != 1 || events[0].DeviceID != "dev_air" || events[0].TrackID != "host-track-1" {
			t.Fatalf("unexpected immediate sync events: %#v", events)
		}
	case <-time.After(500 * time.Millisecond):
		observer.assertNoErrors(t)
		t.Fatalf("expected playback to trigger immediate sync")
	}
}

func TestIncrementPlayCountImmediateSyncSkipsHeavyLibraryWork(t *testing.T) {
	newTempSyncStore(t)
	resetImmediatePlaybackSyncStateForTest()
	songPath := filepath.Join(t.TempDir(), "portable.flac")
	if err := os.WriteFile(songPath, []byte("audio"), 0o644); err != nil {
		t.Fatalf("write audio: %v", err)
	}
	song := map[string]interface{}{
		"id":                 "local-imported-id",
		"syncSourceDeviceId": "dev_host",
		"syncSourceTrackId":  "host-track-1",
		"path":               songPath,
		"title":              "Portable Song",
		"artist":             "Artist",
		"album":              "Album",
		"duration":           180.0,
	}
	received := make(chan []uxsync.PlayEvent, 1)
	unexpectedHeavyRequest := make(chan string, 1)
	observer := &handlerObserver{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion, Roles: []string{"LibraryHost"}})
		case "/sync/library/events":
			var req syncLibraryEventsRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				observer.errorf("decode events: %v", err)
				http.Error(w, "bad events payload", http.StatusBadRequest)
				return
			}
			received <- req.PlayEvents
			writeJSON(w, syncLibraryEventsResponse{Accepted: len(req.PlayEvents), Ack: uxsync.EventAck{DeviceID: req.DeviceID, MaxDeviceSequence: 1}})
		case "/sync/library/snapshot":
			unexpectedHeavyRequest <- r.URL.Path
			http.Error(w, "snapshot should not run during immediate playback sync", http.StatusInternalServerError)
		default:
			if strings.HasPrefix(r.URL.Path, "/sync/assets/") {
				unexpectedHeavyRequest <- r.URL.Path
				http.Error(w, "asset sync should not run during immediate playback sync", http.StatusInternalServerError)
				return
			}
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_air",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	NewApp().IncrementPlayCount(song)

	select {
	case events := <-received:
		observer.assertNoErrors(t)
		if len(events) != 1 || events[0].TrackID != "host-track-1" {
			t.Fatalf("unexpected immediate sync events: %#v", events)
		}
	case <-time.After(500 * time.Millisecond):
		observer.assertNoErrors(t)
		t.Fatalf("expected playback to push play events")
	}
	select {
	case path := <-unexpectedHeavyRequest:
		t.Fatalf("immediate playback sync should only push play events, got request %s", path)
	case <-time.After(200 * time.Millisecond):
	}
	observer.assertNoErrors(t)
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

func TestSyncLibraryEventsAppliesIncomingPlayCountsByMetadataWithoutPulledTrack(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "local.flac")
	song := map[string]interface{}{
		"id":       "local-track",
		"path":     songPath,
		"title":    "Same Song",
		"artist":   "Same Artist",
		"album":    "Same Album",
		"duration": 181.0,
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	postSyncLibraryEvents(t, syncEventsPayload(t, "dev_other", []uxsync.PlayEvent{{
		EventID:          "evt_other_1",
		TrackID:          "remote-random-id",
		DeviceID:         "dev_other",
		DeviceSequence:   1,
		MatchKey:         syncSongMatchKey(song),
		PlayedAt:         time.Date(2026, 6, 9, 6, 20, 0, 0, time.UTC),
		CountedAt:        time.Date(2026, 6, 9, 6, 23, 0, 0, time.UTC),
		DurationPlayedMs: 181000,
		Completed:        true,
	}}))

	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[songPath].(map[string]interface{})
	if entry == nil || entry["count"] != float64(1) {
		t.Fatalf("expected metadata matched event to apply to local path, got %#v", counts)
	}
	if _, ok := counts["remote-random-id"]; ok {
		t.Fatalf("expected no remote track ghost entry, got %#v", counts)
	}
}

func TestSyncLibraryEventsSkipsUnmatchedPlayCountsWithoutGhostEntry(t *testing.T) {
	newTempSyncStore(t)

	postSyncLibraryEvents(t, syncEventsPayload(t, "dev_other", []uxsync.PlayEvent{{
		EventID:          "evt_other_ghost",
		TrackID:          "remote-missing-id",
		DeviceID:         "dev_other",
		DeviceSequence:   1,
		MatchKey:         syncSongMatchKey(map[string]interface{}{"title": "Missing", "artist": "Nobody", "duration": 90.0}),
		PlayedAt:         time.Date(2026, 6, 9, 7, 0, 0, 0, time.UTC),
		CountedAt:        time.Date(2026, 6, 9, 7, 2, 0, 0, time.UTC),
		DurationPlayedMs: 90000,
		Completed:        true,
	}}))

	events := readStoredSyncPlayEvents(t)
	if len(events) != 1 {
		t.Fatalf("expected unmatched event to remain in log, got %#v", events)
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	if len(counts) != 0 {
		t.Fatalf("expected unmatched event not to create playcount entries, got %#v", counts)
	}
}

func TestIncrementPlayCountMigratesExistingCountsToBaseBeforeProjection(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "legacy.flac")
	song := map[string]interface{}{
		"id":       "legacy-track",
		"path":     songPath,
		"title":    "Legacy Song",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 200.0,
	}
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey: "dev_local",
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		songPath: map[string]interface{}{"count": 5.0, "history": []interface{}{"legacy-a", "legacy-b"}},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}
	if err := store.Instance.Save(syncPlayEventsStoreName, []uxsync.PlayEvent{
		countedEvent("evt_existing_1", "dev_other", "legacy-track", syncSongMatchKey(song), 1),
		countedEvent("evt_existing_2", "dev_other", "legacy-track", syncSongMatchKey(song), 2),
	}); err != nil {
		t.Fatalf("seed sync events: %v", err)
	}

	NewApp().IncrementPlayCount(song)

	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[songPath].(map[string]interface{})
	if entry == nil || entry["count"] != float64(6) {
		t.Fatalf("expected migrated count 5 plus one new event, got %#v", counts)
	}
	base, err := store.Instance.LoadMap(syncPlayCountBaseStoreName)
	if err != nil {
		t.Fatalf("load playcount base: %v", err)
	}
	baseEntry, _ := base[songPath].(map[string]interface{})
	if baseEntry == nil || baseEntry["count"] != float64(3) {
		t.Fatalf("expected base to subtract existing log count, got %#v", base)
	}
}

func TestIncrementPlayCountKeepsImportedSyncPlayCountBase(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "synced.flac")
	song := map[string]interface{}{
		"id":                "local-imported-id",
		"syncSourceTrackId": "host-track-1",
		"path":              songPath,
		"title":             "Synced Song",
		"artist":            "Artist",
		"album":             "Album",
		"duration":          200.0,
	}
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey: "dev_air",
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseStoreName, map[string]interface{}{}); err != nil {
		t.Fatalf("seed empty base: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseMigrationStoreName, map[string]interface{}{"migrated": true}); err != nil {
		t.Fatalf("seed migrated marker: %v", err)
	}
	if err := applySyncImportedPlayCount(map[string]interface{}{
		"syncPlayCount": map[string]interface{}{"count": 12},
	}, songPath); err != nil {
		t.Fatalf("apply sync playcount: %v", err)
	}

	NewApp().IncrementPlayCount(song)

	if count := loadPlayCountForPath(t, songPath); count != 13 {
		t.Fatalf("expected imported sync count 12 plus one Air play, got %v", count)
	}
	base, err := store.Instance.LoadMap(syncPlayCountBaseStoreName)
	if err != nil {
		t.Fatalf("load playcount base: %v", err)
	}
	baseEntry, _ := base[songPath].(map[string]interface{})
	if baseEntry == nil || baseEntry["count"] != float64(12) {
		t.Fatalf("expected imported sync count to be kept as base, got %#v", base)
	}
}

func TestSyncPlayCountsConvergeAcrossBidirectionalMetadataMatchedEvents(t *testing.T) {
	dirA := t.TempDir()
	dirB := t.TempDir()
	pathA := filepath.Join(dirA, "same-a.flac")
	pathB := filepath.Join(dirB, "same-b.flac")
	songA := map[string]interface{}{"id": "machine-a-id", "path": pathA, "title": "Converge", "artist": "Artist", "album": "Album", "duration": 210.0}
	songB := map[string]interface{}{"id": "machine-b-id", "path": pathB, "title": "converge", "artist": "artist", "album": "album", "duration": 210.0}

	setSyncTestStore(t, dirA)
	seedSyncDeviceAndLibrary(t, "dev_a", songA)
	NewApp().IncrementPlayCount(songA)
	eventsA := readStoredSyncPlayEvents(t)

	setSyncTestStore(t, dirB)
	seedSyncDeviceAndLibrary(t, "dev_b", songB)
	NewApp().IncrementPlayCount(songB)
	postSyncLibraryEvents(t, syncEventsPayload(t, "dev_a", eventsA))
	eventsB := readStoredSyncPlayEvents(t)
	countB := loadPlayCountForPath(t, pathB)

	setSyncTestStore(t, dirA)
	postSyncLibraryEvents(t, syncEventsPayload(t, "dev_b", eventsB))
	countA := loadPlayCountForPath(t, pathA)

	if countA != 2 || countB != 2 {
		t.Fatalf("expected both machines to converge to 2 plays, got A=%v B=%v", countA, countB)
	}
}

func TestSyncLibraryEventsFallsBackToTrackIDForLegacyEventsWithoutMatchKey(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "legacy-event.flac")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "host-track-legacy", "path": songPath, "title": "Legacy Event"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	postSyncLibraryEvents(t, syncEventsPayload(t, "dev_old", []uxsync.PlayEvent{{
		EventID:          "evt_old_1",
		TrackID:          "host-track-legacy",
		DeviceID:         "dev_old",
		DeviceSequence:   1,
		PlayedAt:         time.Date(2026, 6, 9, 8, 0, 0, 0, time.UTC),
		CountedAt:        time.Date(2026, 6, 9, 8, 3, 0, 0, time.UTC),
		DurationPlayedMs: 180000,
		Completed:        true,
	}}))

	if count := loadPlayCountForPath(t, songPath); count != 1 {
		t.Fatalf("expected legacy event to apply by track id fallback, got %v", count)
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
	observer := &handlerObserver{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion})
		case "/sync/library/events":
			observedToken = r.Header.Get("X-UX-Music-Sync-Token")
			var req syncLibraryEventsRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				observer.errorf("decode events: %v", err)
				http.Error(w, "bad events payload", http.StatusBadRequest)
				return
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
	observer.assertNoErrors(t)
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

func TestAutoSyncPairedDevicesAppliesRemotePlayCountSnapshotWithoutAssetPull(t *testing.T) {
	newTempSyncStore(t)
	localPath := filepath.Join(t.TempDir(), "same-song.flac")
	if err := os.WriteFile(localPath, []byte("local-audio"), 0o644); err != nil {
		t.Fatalf("seed local audio: %v", err)
	}
	localSong := map[string]interface{}{
		"id":       "local-track",
		"path":     localPath,
		"title":    "Same Song",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
	}
	if err := store.Instance.Save("library", []map[string]interface{}{localSong}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		localPath: map[string]interface{}{"count": 2.0},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseStoreName, map[string]interface{}{}); err != nil {
		t.Fatalf("seed base: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseMigrationStoreName, map[string]interface{}{"migrated": true}); err != nil {
		t.Fatalf("seed base migration: %v", err)
	}

	assetRequests := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion, Roles: []string{"LibraryHost"}})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{{
					"id":       "remote-track",
					"title":    "same song",
					"artist":   "artist",
					"album":    "album",
					"duration": 180.0,
					"syncPlayCount": map[string]interface{}{
						"count":   37,
						"history": []interface{}{"2026-06-10T03:00:00Z"},
					},
				}},
			})
		default:
			if strings.HasPrefix(r.URL.Path, "/sync/assets/") {
				assetRequests++
				http.Error(w, "playcount metadata sync should not download assets", http.StatusInternalServerError)
				return
			}
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_air",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.FailedDevices != 0 || assetRequests != 0 {
		t.Fatalf("expected metadata-only sync without asset pulls, result=%#v assetRequests=%d", result, assetRequests)
	}
	if count := loadPlayCountForPath(t, localPath); count != 37 {
		t.Fatalf("expected snapshot playcount to update local base count, got %v", count)
	}
	base, err := store.Instance.LoadMap(syncPlayCountBaseStoreName)
	if err != nil {
		t.Fatalf("load base: %v", err)
	}
	baseEntry, _ := base[localPath].(map[string]interface{})
	if baseEntry == nil || baseEntry["count"] != float64(37) {
		t.Fatalf("expected snapshot playcount in base, got %#v", base)
	}
}

func TestApplySyncPlayCountSnapshotSubtractsLocalEventProjectionFromBase(t *testing.T) {
	newTempSyncStore(t)
	localPath := filepath.Join(t.TempDir(), "same-song.flac")
	localSong := map[string]interface{}{
		"id":       "local-track",
		"path":     localPath,
		"title":    "Same Song",
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
	}
	if err := store.Instance.Save("library", []map[string]interface{}{localSong}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseStoreName, map[string]interface{}{
		localPath: map[string]interface{}{"count": 102.0},
	}); err != nil {
		t.Fatalf("seed inflated base: %v", err)
	}
	if err := store.Instance.Save(syncPlayCountBaseMigrationStoreName, map[string]interface{}{"migrated": true}); err != nil {
		t.Fatalf("seed base migration: %v", err)
	}
	matchKey := syncSongMatchKey(localSong)
	if err := store.Instance.Save(syncPlayEventsStoreName, []uxsync.PlayEvent{
		countedEvent("evt_air_1", "dev_air", "local-track", matchKey, 1),
		countedEvent("evt_air_2", "dev_air", "local-track", matchKey, 2),
		countedEvent("evt_mini_1", "dev_host", "remote-track", matchKey, 1),
	}); err != nil {
		t.Fatalf("seed events: %v", err)
	}

	updated, err := applySyncPlayCountSnapshot("dev_host", []map[string]interface{}{{
		"id":       "remote-track",
		"title":    "same song",
		"artist":   "artist",
		"album":    "album",
		"duration": 180.0,
		"syncPlayCount": map[string]interface{}{
			"count": 102,
		},
	}})
	if err != nil {
		t.Fatalf("apply snapshot: %v", err)
	}
	if updated != 1 {
		t.Fatalf("expected one snapshot playcount update, got %d", updated)
	}
	base, err := store.Instance.LoadMap(syncPlayCountBaseStoreName)
	if err != nil {
		t.Fatalf("load base: %v", err)
	}
	baseEntry, _ := base[localPath].(map[string]interface{})
	if baseEntry == nil || baseEntry["count"] != float64(99) {
		t.Fatalf("expected base to store peer total minus local event projection, got %#v", base)
	}
	if count := loadPlayCountForPath(t, localPath); count != 102 {
		t.Fatalf("expected final playcount to match peer total without double counting, got %v", count)
	}
}

func syncEventsPayload(t *testing.T, deviceID string, events []uxsync.PlayEvent) []byte {
	t.Helper()
	bytes, err := json.Marshal(syncLibraryEventsRequest{DeviceID: deviceID, PlayEvents: events})
	if err != nil {
		t.Fatalf("marshal sync events payload: %v", err)
	}
	return bytes
}

func countedEvent(eventID, deviceID, trackID, matchKey string, sequence int64) uxsync.PlayEvent {
	playedAt := time.Date(2026, 6, 9, 9, int(sequence), 0, 0, time.UTC)
	return uxsync.PlayEvent{
		EventID:          eventID,
		TrackID:          trackID,
		DeviceID:         deviceID,
		DeviceSequence:   sequence,
		MatchKey:         matchKey,
		PlayedAt:         playedAt,
		CountedAt:        playedAt.Add(3 * time.Minute),
		DurationPlayedMs: 180000,
		Completed:        true,
	}
}

// setSyncTestStore は呼び出し側が用意した dir を userDataPath に差し込む。
// newTempUserDataStore と同様、プロセスグローバルを書き換えるので終了時に
// 直前の値へ戻す。戻さないと後続テストが削除済みパスを引き継ぐ。
func setSyncTestStore(t *testing.T, dir string) {
	t.Helper()
	prevPath := config.GetUserDataPath()
	prevStore := store.Instance
	config.Instance.SetUserDataPath(dir)
	store.Instance = &store.Store{}
	t.Cleanup(func() {
		config.SetUserDataPath(prevPath)
		store.Instance = prevStore
	})
}

func seedSyncDeviceAndLibrary(t *testing.T, deviceID string, song map[string]interface{}) {
	t.Helper()
	if err := store.Instance.Save("settings", map[string]interface{}{syncDeviceIDSettingsKey: deviceID}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{song}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
}

func loadPlayCountForPath(t *testing.T, path string) float64 {
	t.Helper()
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[path].(map[string]interface{})
	if entry == nil {
		t.Fatalf("missing playcount for %s in %#v", path, counts)
	}
	count, _ := entry["count"].(float64)
	return count
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

func TestAutoSyncPairedDevicesPullsOnlyMissingTracksFromLibraryHost(t *testing.T) {
	newTempSyncStore(t)
	dir := t.TempDir()
	existingPath := filepath.Join(dir, "existing.flac")
	if err := os.WriteFile(existingPath, []byte("already-here"), 0o644); err != nil {
		t.Fatalf("seed existing file: %v", err)
	}
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":                 "local-existing-id",
			"path":               existingPath,
			"title":              "Existing",
			"syncSourceDeviceId": "dev_host",
			"syncSourceTrackId":  "remote-existing",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	assetRequests := map[string]int{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", ProtocolVersion: syncProtocolVersion, Roles: []string{"LibraryHost"}})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 2,
				Tracks: []map[string]interface{}{
					{"id": "remote-existing", "path": "/Music/existing.flac", "title": "Existing", "artist": "Artist", "album": "Album"},
					{"id": "remote-new", "path": "/Music/new.flac", "title": "New", "artist": "Artist", "album": "Album"},
				},
			})
		case "/sync/assets/remote-new/file":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			assetRequests[r.URL.Path]++
			w.Header().Set("Content-Disposition", `attachment; filename="new.flac"`)
			_, _ = w.Write([]byte("new-audio"))
		case "/sync/assets/remote-existing/file":
			assetRequests[r.URL.Path]++
			http.Error(w, "existing track should have been skipped", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL, Roles: []string{"LibraryHost"}}},
	}); err != nil {
		t.Fatalf("seed known peer: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.PulledTracks != 1 || result.SkippedTracks != 1 || result.FailedDevices != 0 {
		t.Fatalf("unexpected auto pull counters: %#v", result)
	}
	if assetRequests["/sync/assets/remote-existing/file"] != 0 || assetRequests["/sync/assets/remote-new/file"] != 1 {
		t.Fatalf("unexpected asset requests: %#v", assetRequests)
	}
}

func TestAutoSyncPairedDevicesDoesNotPullTracksFromNonLibraryHost(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_peer": "tok_peer"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	snapshotRequests := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_peer", DisplayName: "Controller", ProtocolVersion: syncProtocolVersion, Roles: []string{"Controller"}})
		case "/sync/library/snapshot":
			snapshotRequests++
			http.Error(w, "non LibraryHost should not be pulled", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_peer": "tok_peer"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_peer", DisplayName: "Controller", BaseURL: remote.URL, Roles: []string{"Controller"}}},
	}); err != nil {
		t.Fatalf("seed known peer: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.PulledTracks != 0 || result.SkippedTracks != 0 || snapshotRequests != 0 {
		t.Fatalf("expected no auto pull from non LibraryHost, result=%#v snapshots=%d", result, snapshotRequests)
	}
}

func TestAutoSyncPairedDevicesStopsWhenFreeSpaceIsBelowSafetyLimit(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:       "dev_portable",
		syncMinFreeSpaceGBSettingsKey: 5.0,
		syncAuthTokensSettingsKey:     map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey:     []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: "http://127.0.0.1:1"}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	originalFreeSpace := syncAvailableFreeSpaceBytes
	syncAvailableFreeSpaceBytes = func(string) (uint64, error) {
		return 2 * 1024 * 1024 * 1024, nil
	}
	t.Cleanup(func() { syncAvailableFreeSpaceBytes = originalFreeSpace })

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if !result.Paused || result.CheckedDevices != 0 {
		t.Fatalf("expected auto sync to pause before peer access, got %#v", result)
	}
	if result.MinFreeSpaceBytes != 5*1024*1024*1024 || result.FreeSpaceBytes != 2*1024*1024*1024 {
		t.Fatalf("unexpected free space counters: %#v", result)
	}
}

func TestSyncAutoResultIsNotable(t *testing.T) {
	cases := []struct {
		name   string
		result SyncAutoResult
		want   bool
	}{
		{"接続確認のみは通知しない", SyncAutoResult{CheckedDevices: 1, SyncedDevices: 1}, false},
		{"既存曲のスキップのみは通知しない", SyncAutoResult{CheckedDevices: 1, SyncedDevices: 1, SkippedTracks: 12}, false},
		{"新規取得は通知する", SyncAutoResult{CheckedDevices: 1, PulledTracks: 1}, true},
		{"再生回数の送信は通知する", SyncAutoResult{CheckedDevices: 1, PushedPlayEvents: 3}, true},
		{"ジャケット同期は通知する", SyncAutoResult{CheckedDevices: 1, SyncedArtwork: 2}, true},
		{"一時停止は通知する", SyncAutoResult{Paused: true, PauseReason: "free-space-below-limit"}, true},
		{"失敗は通知する", SyncAutoResult{CheckedDevices: 1, FailedDevices: 1, Errors: []string{"boom"}}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := syncAutoResultIsNotable(tc.result); got != tc.want {
				t.Fatalf("syncAutoResultIsNotable(%+v) = %v, want %v", tc.result, got, tc.want)
			}
		})
	}
}
