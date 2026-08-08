package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/store"
)

func TestGetUnifiedLibraryMarksLocalSongs(t *testing.T) {
	newTempSyncStore(t)
	localPath := filepath.Join(t.TempDir(), "local.flac")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "local-1", "path": localPath, "title": "Local", "artist": "Artist", "album": "Album", "duration": 180.0},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	result, err := NewApp().GetUnifiedLibrary()
	if err != nil {
		t.Fatalf("GetUnifiedLibrary: %v", err)
	}
	songs, _ := result["songs"].([]interface{})
	if len(songs) != 1 {
		t.Fatalf("expected one local song, got %#v", result)
	}
	song, _ := songs[0].(map[string]interface{})
	if song["syncAvailability"] != "local" || song["path"] != localPath {
		t.Fatalf("expected local availability, got %#v", song)
	}
}

func TestGetUnifiedLibraryAddsRemoteOnlySongs(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_host": map[string]interface{}{
			"displayName": "Mac mini",
			"baseUrl":     "http://host.local:8765",
			"tracks": []interface{}{
				map[string]interface{}{"id": "remote-1", "title": "Remote", "artist": "Artist", "album": "Album", "duration": 180.0, "path": "/remote/remote.flac"},
			},
		},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}

	result, err := NewApp().GetUnifiedLibrary()
	if err != nil {
		t.Fatalf("GetUnifiedLibrary: %v", err)
	}
	songs, _ := result["songs"].([]interface{})
	if len(songs) != 1 {
		t.Fatalf("expected one remote song, got %#v", result)
	}
	song, _ := songs[0].(map[string]interface{})
	if song["syncAvailability"] != "remote" || song["syncSourceDeviceId"] != "dev_host" || song["syncSourcePeerName"] != "Mac mini" || song["syncSourceTrackId"] != "remote-1" {
		t.Fatalf("expected remote sync metadata, got %#v", song)
	}
	if path, _ := song["path"].(string); path != "" {
		t.Fatalf("expected remote song not to expose a local path, got %#v", song)
	}
}

func TestGetUnifiedLibraryDeduplicatesRemoteWhenLocalMatches(t *testing.T) {
	newTempSyncStore(t)
	local := map[string]interface{}{"id": "local-1", "path": filepath.Join(t.TempDir(), "same.flac"), "title": "Same", "artist": "Artist", "album": "Album", "duration": 200.0}
	if err := store.Instance.Save("library", []map[string]interface{}{local}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_host": map[string]interface{}{
			"displayName": "Mac mini",
			"tracks": []interface{}{
				map[string]interface{}{"id": "remote-same", "title": " same ", "artist": "artist", "album": "album", "duration": 200.0},
			},
		},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}

	result, err := NewApp().GetUnifiedLibrary()
	if err != nil {
		t.Fatalf("GetUnifiedLibrary: %v", err)
	}
	songs, _ := result["songs"].([]interface{})
	if len(songs) != 1 {
		t.Fatalf("expected local match to suppress remote duplicate, got %#v", result)
	}
	song, _ := songs[0].(map[string]interface{})
	if song["syncAvailability"] != "local" || song["id"] != "local-1" {
		t.Fatalf("expected local song to win, got %#v", song)
	}
}

func TestGetUnifiedLibraryDeduplicatesSameRemoteAcrossPeers(t *testing.T) {
	newTempSyncStore(t)
	track := map[string]interface{}{"id": "remote-a", "title": "Union", "artist": "Artist", "album": "Album", "duration": 210.0}
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_a": map[string]interface{}{"displayName": "A", "tracks": []interface{}{track}},
		"dev_b": map[string]interface{}{"displayName": "B", "tracks": []interface{}{map[string]interface{}{"id": "remote-b", "title": "union", "artist": "artist", "album": "album", "duration": 210.0}}},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}

	result, err := NewApp().GetUnifiedLibrary()
	if err != nil {
		t.Fatalf("GetUnifiedLibrary: %v", err)
	}
	songs, _ := result["songs"].([]interface{})
	if len(songs) != 1 {
		t.Fatalf("expected one remote union item, got %#v", result)
	}
}

func TestRefreshSyncRemoteCatalogStoresSnapshotAndPreservesExistingOnFailure(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		deviceAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host", "dev_stale": "tok_stale"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_stale": map[string]interface{}{"displayName": "Stale", "tracks": []interface{}{map[string]interface{}{"id": "old"}}},
	}); err != nil {
		t.Fatalf("seed stale catalog: %v", err)
	}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok_host" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, syncLibrarySnapshotResponse{
			DeviceID:    "dev_host",
			DisplayName: "Mac mini",
			GeneratedAt: "2026-06-09T07:50:00Z",
			Tracks: []map[string]interface{}{
				{"id": "remote-1", "title": "Remote"},
			},
		})
	}))
	defer remote.Close()

	err := refreshSyncRemoteCatalog(context.Background(), []SyncDeviceRecord{
		{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL, Roles: []string{"LibraryHost"}, Paired: true},
		{DeviceID: "dev_stale", DisplayName: "Stale", BaseURL: "http://127.0.0.1:1", Roles: []string{"LibraryHost"}, Paired: true},
	})
	if err != nil {
		t.Fatalf("refreshSyncRemoteCatalog: %v", err)
	}
	catalog, err := store.Instance.LoadMap(syncRemoteCatalogStoreName)
	if err != nil {
		t.Fatalf("load remote catalog: %v", err)
	}
	host, _ := catalog["dev_host"].(map[string]interface{})
	if host == nil || host["displayName"] != "Mac mini" {
		t.Fatalf("expected fresh host catalog, got %#v", catalog)
	}
	stale, _ := catalog["dev_stale"].(map[string]interface{})
	tracks, _ := stale["tracks"].([]interface{})
	if len(tracks) != 1 {
		t.Fatalf("expected failed peer catalog to be preserved, got %#v", catalog)
	}
}

func TestDownloadSyncTrackImportsRemoteCatalogTrack(t *testing.T) {
	newTempSyncStore(t)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/sync/assets/remote-track-1/file":
			if r.Header.Get("Authorization") != "Bearer tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="remote.flac"`)
			_, _ = w.Write([]byte("remote-audio"))
		case "/v1/sync/assets/remote-track-1/artwork":
			if r.Header.Get("Authorization") != "Bearer tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="cover.webp"`)
			_, _ = w.Write([]byte("remote-artwork"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_portable",
		deviceAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: remote.URL, Roles: []string{"LibraryHost"}}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_host": map[string]interface{}{
			"displayName": "Mac mini",
			"baseUrl":     remote.URL,
			"tracks": []interface{}{
				map[string]interface{}{"id": "remote-track-1", "title": "Remote", "artist": "Artist", "album": "Album", "duration": 180.0},
			},
		},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}

	result, err := NewApp().DownloadSyncTrack("dev_host", "remote-track-1")
	if err != nil {
		t.Fatalf("DownloadSyncTrack: %v", err)
	}
	if result.Downloaded != 1 || len(result.ImportedPaths) != 1 {
		t.Fatalf("expected one downloaded path, got %#v", result)
	}
	if _, err := os.Stat(result.ImportedPaths[0]); err != nil {
		t.Fatalf("expected downloaded file: %v", err)
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	if len(library) != 1 {
		t.Fatalf("expected imported library entry, got %#v", library)
	}
	imported, _ := library[0].(map[string]interface{})
	if imported["syncSourceDeviceId"] != "dev_host" || imported["syncSourceTrackId"] != "remote-track-1" {
		t.Fatalf("expected imported sync source metadata, got %#v", imported)
	}
	requireSyncArtworkFiles(t, imported, "downloaded sync track")
}

func TestDownloadSyncTrackFailsWithoutReachablePeerOrToken(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_host": map[string]interface{}{
			"displayName": "Mac mini",
			"baseUrl":     "http://127.0.0.1:1",
			"tracks": []interface{}{
				map[string]interface{}{"id": "remote-track-1", "title": "Remote"},
			},
		},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}

	if _, err := NewApp().DownloadSyncTrack("dev_host", "remote-track-1"); err == nil {
		t.Fatal("expected missing token or peer to fail")
	}
}
