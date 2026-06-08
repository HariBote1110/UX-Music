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
)

func TestSyncLibrarySnapshotRequiresTokenAndReturnsLibraryTracks(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":     "track-1",
			"path":   filepath.Join(t.TempDir(), "song.flac"),
			"title":  "Song",
			"artist": "Artist",
			"artwork": map[string]interface{}{
				"full": "large artwork payload is omitted",
			},
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	handler := NewLANHTTPHandler(NewApp())
	missing := httptest.NewRecorder()
	handler.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/sync/library/snapshot", nil))
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("expected snapshot to require sync token, got %d", missing.Code)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/library/snapshot", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibrarySnapshotResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Count != 1 || len(response.Tracks) != 1 {
		t.Fatalf("unexpected snapshot count: %#v", response)
	}
	if _, exists := response.Tracks[0]["artwork"]; exists {
		t.Fatalf("snapshot should omit artwork blobs: %#v", response.Tracks[0])
	}
}

func TestSyncAssetFileServesOriginalFileByTrackID(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "source.flac")
	if err := os.WriteFile(audioPath, []byte("audio-bytes"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": audioPath},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/file", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "audio-bytes" {
		t.Fatalf("unexpected file body %q", got)
	}
}

func TestPullSyncLibraryAssetsDownloadsRemoteTrackIntoManagedLibrary(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini"})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{
					{
						"id":          "remote-track-1",
						"path":        "/Volumes/Music/source.flac",
						"title":       "Song",
						"artist":      "Artist",
						"album":       "Album",
						"albumartist": "Artist",
						"fileType":    ".flac",
					},
				},
			})
		case "/sync/assets/remote-track-1/file":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="source.flac"`)
			_, _ = w.Write([]byte("remote-audio"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 1 || result.Skipped != 0 {
		t.Fatalf("unexpected pull result: %#v", result)
	}

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	if len(library) != 1 {
		t.Fatalf("expected one imported track, got %#v", library)
	}
	imported := library[0].(map[string]interface{})
	importedPath, _ := imported["path"].(string)
	if imported["syncSourceDeviceId"] != "dev_host" || imported["syncSourceTrackId"] != "remote-track-1" {
		t.Fatalf("missing source markers: %#v", imported)
	}
	if !filepath.IsAbs(importedPath) || filepath.Dir(importedPath) == config.GetUserDataPath() {
		t.Fatalf("expected managed nested destination, got %q", importedPath)
	}
	bytes, err := os.ReadFile(importedPath)
	if err != nil {
		t.Fatalf("read imported file: %v", err)
	}
	if string(bytes) != "remote-audio" {
		t.Fatalf("unexpected imported bytes %q", string(bytes))
	}
}

func TestResetSyncTestDataKeepsPairingSettingsAndClearsManagedMusicState(t *testing.T) {
	newTempSyncStore(t)
	userData := config.GetUserDataPath()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", BaseURL: "http://192.168.0.226:8765"}},
		"libraryPath":            filepath.Join(t.TempDir(), "old-library"),
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	for _, name := range []string{"library", "playcounts", "loudness", "analysed-queue", syncPlayEventsStoreName} {
		if err := store.Instance.Save(name, map[string]interface{}{"stale": true}); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	for _, dir := range []string{"Artworks", "WearCache", "SyncLibrary", "Playlists"} {
		path := filepath.Join(userData, dir)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("seed dir %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(path, "stale"), []byte("x"), 0o644); err != nil {
			t.Fatalf("seed dir file %s: %v", dir, err)
		}
	}

	result, err := ResetSyncTestData()
	if err != nil {
		t.Fatalf("ResetSyncTestData: %v", err)
	}
	if result.RemovedCount == 0 {
		t.Fatalf("expected reset to remove files or directories: %#v", result)
	}
	if _, err := os.Stat(store.Instance.GetPath("library")); !os.IsNotExist(err) {
		t.Fatalf("expected library store to be removed, stat err=%v", err)
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	if _, ok := settings[syncAuthTokensSettingsKey]; !ok {
		t.Fatalf("expected sync tokens to be preserved: %#v", settings)
	}
	if _, ok := settings[syncKnownPeersSettingsKey]; !ok {
		t.Fatalf("expected known peers to be preserved: %#v", settings)
	}
	wantLibraryPath := filepath.Join(userData, "SyncLibrary")
	if settings["libraryPath"] != wantLibraryPath {
		t.Fatalf("expected libraryPath to be reset to %q, got %#v", wantLibraryPath, settings["libraryPath"])
	}
}
