package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/store"
)

func TestAutoSyncPairedDevicesSelectivePullsOnlyRecentRemoteTracks(t *testing.T) {
	newTempSyncStore(t)
	assetRequests := map[string]int{}
	remote := syncCacheTestServer(t, assetRequests)
	seedSyncCacheSettings(t, "selective", remote.URL)
	seedSyncCacheCatalog(t, remote.URL)
	recentPath := syncCacheExpectedPath("remote-recent", "Recent")
	olderPath := syncCacheExpectedPath("remote-older", "Older")
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		recentPath: map[string]interface{}{"count": 1.0, "history": []interface{}{"2026-06-09T08:20:00Z"}},
		olderPath:  map[string]interface{}{"count": 1.0, "history": []interface{}{"2026-06-09T07:20:00Z"}},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.PulledTracks != 1 || result.SkippedTracks != 0 {
		t.Fatalf("expected selective sync to pull only one recent remote track, got %#v", result)
	}
	if assetRequests["/sync/assets/remote-recent/file"] != 1 || assetRequests["/sync/assets/remote-older/file"] != 0 {
		t.Fatalf("unexpected selective asset requests: %#v", assetRequests)
	}
}

func TestAutoSyncPairedDevicesMirrorPolicyPullsAllTracksByDefault(t *testing.T) {
	newTempSyncStore(t)
	assetRequests := map[string]int{}
	remote := syncCacheTestServer(t, assetRequests)
	seedSyncCacheSettings(t, "", remote.URL)

	result, err := NewApp().AutoSyncPairedDevices()
	if err != nil {
		t.Fatalf("AutoSyncPairedDevices: %v", err)
	}
	if result.PulledTracks != 2 {
		t.Fatalf("expected mirror policy to pull all tracks, got %#v", result)
	}
	if assetRequests["/sync/assets/remote-recent/file"] != 1 || assetRequests["/sync/assets/remote-older/file"] != 1 {
		t.Fatalf("unexpected mirror asset requests: %#v", assetRequests)
	}
}

func TestRecentRemoteSyncTrackRefsUsesPlayHistoryOrder(t *testing.T) {
	newTempSyncStore(t)
	seedSyncCacheCatalog(t, "http://host.local:8765")
	recentPath := syncCacheExpectedPath("remote-recent", "Recent")
	olderPath := syncCacheExpectedPath("remote-older", "Older")
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		olderPath:  map[string]interface{}{"history": []interface{}{"2026-06-09T07:20:00Z"}},
		recentPath: map[string]interface{}{"history": []interface{}{"2026-06-09T08:20:00Z"}},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}

	refs := recentRemoteSyncTrackRefs(1)
	if len(refs) != 1 || refs[0].SourceTrackID != "remote-recent" || refs[0].SourceDeviceID != "dev_host" {
		t.Fatalf("expected most recent remote ref, got %#v", refs)
	}
}

func TestPrefetchSyncTracksDownloadsSpecifiedRemoteTracks(t *testing.T) {
	newTempSyncStore(t)
	assetRequests := map[string]int{}
	remote := syncCacheTestServer(t, assetRequests)
	seedSyncCacheSettings(t, "selective", remote.URL)
	seedSyncCacheCatalog(t, remote.URL)

	result, err := NewApp().PrefetchSyncTracks([]SyncTrackRef{{SourceDeviceID: "dev_host", SourceTrackID: "remote-older"}})
	if err != nil {
		t.Fatalf("PrefetchSyncTracks: %v", err)
	}
	if result.Downloaded != 1 || assetRequests["/sync/assets/remote-older/file"] != 1 || assetRequests["/sync/assets/remote-recent/file"] != 0 {
		t.Fatalf("unexpected prefetch result=%#v requests=%#v", result, assetRequests)
	}
}

func TestSelectiveCachePrunesLeastRecentlyUsedImportedTrack(t *testing.T) {
	newTempSyncStore(t)
	seedSyncCacheSettings(t, "selective", "http://host.local:8765")
	seedSyncCacheCatalog(t, "http://host.local:8765")
	oldPath := syncCacheSeedImportedFile(t, "remote-older", "Older")
	newPath := syncCacheSeedImportedFile(t, "remote-recent", "Recent")
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		oldPath: map[string]interface{}{"history": []interface{}{"2026-06-09T07:20:00Z"}},
		newPath: map[string]interface{}{"history": []interface{}{"2026-06-09T08:20:00Z"}},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}
	originalFreeSpace := syncAvailableFreeSpaceBytes
	syncAvailableFreeSpaceBytes = func(string) (uint64, error) { return 1, nil }
	t.Cleanup(func() { syncAvailableFreeSpaceBytes = originalFreeSpace })

	removed, err := pruneSelectiveSyncCacheIfNeeded()
	if err != nil {
		t.Fatalf("pruneSelectiveSyncCacheIfNeeded: %v", err)
	}
	if removed != 1 {
		t.Fatalf("expected one LRU removal, got %d", removed)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("expected oldest cached file to be removed, stat err=%v", err)
	}
	if _, err := os.Stat(newPath); err != nil {
		t.Fatalf("expected newer cached file to remain: %v", err)
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	if len(library) != 1 {
		t.Fatalf("expected oldest library entry removed, got %#v", library)
	}
}

func TestMirrorCachePolicyDoesNotPruneWhenFreeSpaceIsLow(t *testing.T) {
	newTempSyncStore(t)
	seedSyncCacheSettings(t, "mirror", "http://host.local:8765")
	path := syncCacheSeedImportedFile(t, "remote-older", "Older")
	originalFreeSpace := syncAvailableFreeSpaceBytes
	syncAvailableFreeSpaceBytes = func(string) (uint64, error) { return 1, nil }
	t.Cleanup(func() { syncAvailableFreeSpaceBytes = originalFreeSpace })

	removed, err := pruneSelectiveSyncCacheIfNeeded()
	if err != nil {
		t.Fatalf("pruneSelectiveSyncCacheIfNeeded: %v", err)
	}
	if removed != 0 {
		t.Fatalf("expected mirror policy not to prune, got %d", removed)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected mirror cached file to remain: %v", err)
	}
}

func syncCacheTestServer(t *testing.T, assetRequests map[string]int) *httptest.Server {
	t.Helper()
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
				DeviceID:    "dev_host",
				DisplayName: "Mac mini",
				Tracks: []map[string]interface{}{
					syncCacheRemoteTrack("remote-recent", "Recent"),
					syncCacheRemoteTrack("remote-older", "Older"),
				},
			})
		case "/sync/assets/remote-recent/file", "/sync/assets/remote-older/file":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			assetRequests[r.URL.Path]++
			w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(r.URL.Path)+`.flac"`)
			_, _ = w.Write([]byte("remote-audio"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(remote.Close)
	return remote
}

func seedSyncCacheSettings(t *testing.T, policy, baseURL string) {
	t.Helper()
	settings := map[string]interface{}{
		syncDeviceIDSettingsKey:       "dev_portable",
		syncAuthTokensSettingsKey:     map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey:     []syncKnownPeerRecord{{DeviceID: "dev_host", DisplayName: "Mac mini", BaseURL: baseURL, Roles: []string{"LibraryHost"}}},
		syncMinFreeSpaceGBSettingsKey: 5.0,
	}
	if policy != "" {
		settings[syncCachePolicySettingsKey] = policy
	}
	if err := store.Instance.Save("settings", settings); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
}

func seedSyncCacheCatalog(t *testing.T, baseURL string) {
	t.Helper()
	if err := store.Instance.Save(syncRemoteCatalogStoreName, map[string]interface{}{
		"dev_host": map[string]interface{}{
			"displayName": "Mac mini",
			"baseUrl":     baseURL,
			"tracks": []interface{}{
				syncCacheRemoteTrack("remote-recent", "Recent"),
				syncCacheRemoteTrack("remote-older", "Older"),
			},
		},
	}); err != nil {
		t.Fatalf("seed remote catalog: %v", err)
	}
}

func syncCacheRemoteTrack(id, title string) map[string]interface{} {
	return map[string]interface{}{
		"id":       id,
		"title":    title,
		"artist":   "Artist",
		"album":    "Album",
		"duration": 180.0,
		"fileType": "flac",
	}
}

func syncCacheExpectedPath(id, title string) string {
	return syncManagedTrackDestination(syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini"}, syncCacheRemoteTrack(id, title), id+".flac")
}

func syncCacheSeedImportedFile(t *testing.T, id, title string) string {
	t.Helper()
	path := syncCacheExpectedPath(id, title)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create cache dir: %v", err)
	}
	if err := os.WriteFile(path, []byte("cached"), 0o644); err != nil {
		t.Fatalf("seed cached file: %v", err)
	}
	library, _ := store.Instance.LoadSlice("library")
	library = append(library, map[string]interface{}{
		"id":                 "local-" + id,
		"path":               path,
		"title":              title,
		"artist":             "Artist",
		"album":              "Album",
		"syncSourceDeviceId": "dev_host",
		"syncSourceTrackId":  id,
	})
	if err := store.Instance.Save("library", library); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	return path
}
