package server

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"ux-music-sidecar/internal/config"
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

type SyncTrackRef struct {
	SourceDeviceID string `json:"sourceDeviceId"`
	SourceTrackID  string `json:"sourceTrackId"`
}

func (a *App) PrefetchSyncTracks(refs []SyncTrackRef) (SyncPullResult, error) {
	result := SyncPullResult{}
	seen := map[string]bool{}
	for _, ref := range refs {
		deviceID := strings.TrimSpace(ref.SourceDeviceID)
		trackID := strings.TrimSpace(ref.SourceTrackID)
		if deviceID == "" || trackID == "" {
			continue
		}
		key := deviceID + "\x00" + trackID
		if seen[key] {
			continue
		}
		seen[key] = true
		pulled, err := a.DownloadSyncTrack(deviceID, trackID)
		if result.RemoteDeviceID == "" {
			result.RemoteDeviceID = pulled.RemoteDeviceID
			result.RemoteDisplayName = pulled.RemoteDisplayName
		}
		if err != nil {
			result.Failed++
			result.Errors = append(result.Errors, fmt.Sprintf("%s:%s: %v", deviceID, trackID, err))
			continue
		}
		result.Downloaded += pulled.Downloaded
		result.Skipped += pulled.Skipped
		result.ImportedPaths = append(result.ImportedPaths, pulled.ImportedPaths...)
	}
	return result, nil
}

func syncCachePolicy() string {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return "mirror"
	}
	policy := strings.TrimSpace(syncCatalogString(settings, syncCachePolicySettingsKey))
	if policy == "selective" {
		return "selective"
	}
	return "mirror"
}

func recentRemoteSyncTrackRefs(limit int) []SyncTrackRef {
	candidates := recentRemoteSyncCandidates()
	sort.SliceStable(candidates, func(i, j int) bool {
		return candidates[i].LastAccess.After(candidates[j].LastAccess)
	})
	if limit > 0 && len(candidates) > limit {
		candidates = candidates[:limit]
	}
	refs := make([]SyncTrackRef, 0, len(candidates))
	for _, candidate := range candidates {
		if syncImportedTrackExists(candidate.SourceDeviceID, candidate.SourceTrackID) {
			continue
		}
		refs = append(refs, SyncTrackRef{SourceDeviceID: candidate.SourceDeviceID, SourceTrackID: candidate.SourceTrackID})
	}
	return refs
}

func pruneSelectiveSyncCacheIfNeeded() (int, error) {
	if syncCachePolicy() != "selective" {
		return 0, nil
	}
	minBytes := syncMinFreeSpaceBytes()
	if minBytes == 0 {
		return 0, nil
	}
	freeBytes, err := syncAvailableFreeSpaceBytes(config.GetUserDataPath())
	if err != nil {
		return 0, err
	}
	if freeBytes >= minBytes {
		return 0, nil
	}
	return pruneOldestSyncImportedTrack()
}

type syncRemoteCandidate struct {
	SourceDeviceID string
	SourceTrackID  string
	Path           string
	LastAccess     time.Time
}

func recentRemoteSyncCandidates() []syncRemoteCandidate {
	catalog, err := store.Instance.LoadMap(syncRemoteCatalogStoreName)
	if err != nil {
		return nil
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		counts = map[string]interface{}{}
	}
	var candidates []syncRemoteCandidate
	for peerID, raw := range catalog {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		identity := syncIdentityResponse{DeviceID: peerID, DisplayName: syncCatalogString(entry, "displayName")}
		tracks, ok := entry["tracks"].([]interface{})
		if !ok {
			continue
		}
		for _, item := range tracks {
			track, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			trackID := syncTrackID(track)
			if trackID == "" {
				continue
			}
			path := syncManagedTrackDestination(identity, track, syncRemoteTrackFileName(track))
			lastAccess := syncPlayCountLastAccess(counts[path])
			if lastAccess.IsZero() {
				continue
			}
			candidates = append(candidates, syncRemoteCandidate{
				SourceDeviceID: peerID,
				SourceTrackID:  trackID,
				Path:           path,
				LastAccess:     lastAccess,
			})
		}
	}
	return candidates
}

func pruneOldestSyncImportedTrack() (int, error) {
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return 0, err
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		counts = map[string]interface{}{}
	}
	oldestIndex := -1
	oldestAccess := time.Time{}
	oldestPath := ""
	for i, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok || strings.TrimSpace(syncTrackString(song, "syncSourceDeviceId")) == "" {
			continue
		}
		path := syncTrackString(song, "path")
		if path == "" {
			continue
		}
		access := syncPlayCountLastAccess(counts[path])
		if access.IsZero() {
			access = time.Time{}
		}
		if oldestIndex < 0 || access.Before(oldestAccess) {
			oldestIndex = i
			oldestAccess = access
			oldestPath = path
		}
	}
	if oldestIndex < 0 {
		return 0, nil
	}
	if strings.TrimSpace(oldestPath) != "" {
		if err := os.Remove(oldestPath); err != nil && !os.IsNotExist(err) {
			return 0, err
		}
	}
	library = append(library[:oldestIndex], library[oldestIndex+1:]...)
	if err := store.Instance.Save("library", library); err != nil {
		return 0, err
	}
	return 1, nil
}

func syncPlayCountLastAccess(raw interface{}) time.Time {
	entry := normalisePlayCountEntry(raw)
	history, _ := entry["history"].([]interface{})
	for i := len(history) - 1; i >= 0; i-- {
		value, _ := history[i].(string)
		if parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value)); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func syncRemoteTrackFileName(track map[string]interface{}) string {
	if path := syncTrackString(track, "path"); path != "" {
		return path[strings.LastIndex(path, "/")+1:]
	}
	trackID := syncTrackID(track)
	ext := syncTrackString(track, "fileType")
	if ext != "" && !strings.HasPrefix(ext, ".") {
		ext = "." + ext
	}
	return trackID + ext
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
