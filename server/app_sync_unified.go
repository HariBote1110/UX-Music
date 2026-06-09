package server

import (
	"context"
	"fmt"
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

func (a *App) DownloadSyncTrack(sourceDeviceID, sourceTrackID string) (SyncPullResult, error) {
	sourceDeviceID = strings.TrimSpace(sourceDeviceID)
	sourceTrackID = strings.TrimSpace(sourceTrackID)
	if sourceDeviceID == "" || sourceTrackID == "" {
		return SyncPullResult{}, fmt.Errorf("sync source device and track are required")
	}
	if a == nil {
		a = NewApp()
	}
	ctx := context.Background()
	if a.ctx != nil {
		ctx = a.ctx
	}
	if err := ensureSyncFreeSpaceAvailable(); err != nil {
		return SyncPullResult{}, err
	}
	track, catalogEntry, err := syncRemoteCatalogTrack(sourceDeviceID, sourceTrackID)
	if err != nil {
		return SyncPullResult{}, err
	}
	device, err := a.syncDeviceRecordForDownload(sourceDeviceID, catalogEntry)
	if err != nil {
		return SyncPullResult{}, err
	}
	token, err := loadSyncAuthTokenForDevice(sourceDeviceID)
	if err != nil {
		return SyncPullResult{}, err
	}
	baseURL, err := normaliseSyncBaseURL(device.BaseURL)
	if err != nil {
		return SyncPullResult{}, err
	}
	identity := syncIdentityResponse{
		DeviceID:    sourceDeviceID,
		DisplayName: firstNonEmpty(device.DisplayName, syncCatalogString(catalogEntry, "displayName")),
	}
	importedPath, err := downloadSyncTrackAsset(ctx, a, baseURL, token, identity, track, 1, 1)
	if err != nil {
		return SyncPullResult{}, err
	}
	return SyncPullResult{
		RemoteDeviceID:    sourceDeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
		Downloaded:        1,
		ImportedPaths:     []string{importedPath},
	}, nil
}

func syncRemoteCatalogTrack(sourceDeviceID, sourceTrackID string) (map[string]interface{}, map[string]interface{}, error) {
	catalog, err := store.Instance.LoadMap(syncRemoteCatalogStoreName)
	if err != nil {
		return nil, nil, err
	}
	rawEntry, ok := catalog[sourceDeviceID]
	if !ok {
		return nil, nil, fmt.Errorf("sync remote catalog for %s was not found", sourceDeviceID)
	}
	entry, ok := rawEntry.(map[string]interface{})
	if !ok {
		return nil, nil, fmt.Errorf("sync remote catalog for %s is invalid", sourceDeviceID)
	}
	tracks, ok := entry["tracks"].([]interface{})
	if !ok {
		return nil, nil, fmt.Errorf("sync remote catalog tracks for %s are invalid", sourceDeviceID)
	}
	for _, item := range tracks {
		track, ok := item.(map[string]interface{})
		if ok && syncTrackID(track) == sourceTrackID {
			return cloneSyncMap(track), entry, nil
		}
	}
	return nil, nil, fmt.Errorf("sync remote track %s was not found", sourceTrackID)
}

func (a *App) syncDeviceRecordForDownload(sourceDeviceID string, catalogEntry map[string]interface{}) (SyncDeviceRecord, error) {
	devices, err := a.ListSyncDevices()
	if err == nil {
		for _, device := range devices {
			if device.DeviceID == sourceDeviceID && strings.TrimSpace(device.BaseURL) != "" {
				return device, nil
			}
		}
	}
	baseURL := syncCatalogString(catalogEntry, "baseUrl")
	if strings.TrimSpace(baseURL) == "" {
		return SyncDeviceRecord{}, fmt.Errorf("sync peer %s is not reachable", sourceDeviceID)
	}
	return SyncDeviceRecord{
		DeviceID:    sourceDeviceID,
		DisplayName: syncCatalogString(catalogEntry, "displayName"),
		BaseURL:     baseURL,
		Paired:      true,
	}, nil
}

func syncCatalogString(entry map[string]interface{}, key string) string {
	value, _ := entry[key].(string)
	return strings.TrimSpace(value)
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
