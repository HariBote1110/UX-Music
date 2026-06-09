package server

import (
	"context"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
)

func (a *App) RefreshSyncRemoteCatalog() error {
	if a == nil {
		a = NewApp()
	}
	devices, err := a.ListSyncDevices()
	if err != nil {
		return err
	}
	return refreshSyncRemoteCatalog(context.Background(), devices)
}

func refreshSyncRemoteCatalog(ctx context.Context, devices []SyncDeviceRecord) error {
	for _, device := range devices {
		if !device.Paired || strings.TrimSpace(device.BaseURL) == "" || !syncDeviceRecordSupportsLibraryHost(device) {
			continue
		}
		token, err := loadSyncAuthTokenForDevice(device.DeviceID)
		if err != nil {
			continue
		}
		_ = refreshSingleSyncRemoteCatalog(ctx, device, token)
	}
	return nil
}

func refreshSingleSyncRemoteCatalog(ctx context.Context, device SyncDeviceRecord, token string) error {
	snapshot, err := fetchSyncLibrarySnapshot(ctx, strings.TrimRight(device.BaseURL, "/"), token)
	if err != nil {
		return err
	}
	catalog, err := store.Instance.LoadMap(syncRemoteCatalogStoreName)
	if err != nil {
		catalog = map[string]interface{}{}
	}
	deviceID := firstNonEmpty(snapshot.DeviceID, device.DeviceID)
	if deviceID == "" {
		return nil
	}
	displayName := firstNonEmpty(snapshot.DisplayName, device.DisplayName)
	generatedAt := firstNonEmpty(snapshot.GeneratedAt, time.Now().UTC().Format(time.RFC3339))
	tracks := make([]interface{}, 0, len(snapshot.Tracks))
	for _, track := range snapshot.Tracks {
		tracks = append(tracks, cloneSyncMap(track))
	}
	catalog[deviceID] = map[string]interface{}{
		"displayName": displayName,
		"baseUrl":     device.BaseURL,
		"generatedAt": generatedAt,
		"tracks":      tracks,
	}
	return store.Instance.Save(syncRemoteCatalogStoreName, catalog)
}

func syncDeviceRecordSupportsLibraryHost(device SyncDeviceRecord) bool {
	for _, role := range device.Roles {
		if strings.EqualFold(strings.TrimSpace(role), "LibraryHost") {
			return true
		}
	}
	return false
}

func syncUnifiedRemoteSongs(localMatchKeys map[string]bool) []interface{} {
	catalog, err := store.Instance.LoadMap(syncRemoteCatalogStoreName)
	if err != nil {
		return []interface{}{}
	}
	seenRemoteMatchKeys := map[string]bool{}
	var songs []interface{}
	for peerID, raw := range catalog {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		displayName, _ := entry["displayName"].(string)
		tracks, ok := entry["tracks"].([]interface{})
		if !ok {
			continue
		}
		for _, item := range tracks {
			track, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			key := syncSongMatchKey(track)
			if key == "" || localMatchKeys[key] || seenRemoteMatchKeys[key] {
				continue
			}
			seenRemoteMatchKeys[key] = true
			remote := cloneSyncMap(track)
			remote["syncAvailability"] = "remote"
			remote["syncSourceDeviceId"] = peerID
			remote["syncSourcePeerName"] = displayName
			remote["syncSourceTrackId"] = syncTrackID(track)
			delete(remote, "path")
			delete(remote, "artwork")
			songs = append(songs, remote)
		}
	}
	return songs
}

func cloneSyncMap(source map[string]interface{}) map[string]interface{} {
	clone := make(map[string]interface{}, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}
