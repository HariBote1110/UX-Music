package server

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/text/unicode/norm"
)

type SyncAutoResult struct {
	CheckedDevices    int      `json:"checkedDevices"`
	SyncedDevices     int      `json:"syncedDevices"`
	FailedDevices     int      `json:"failedDevices"`
	PushedPlayEvents  int      `json:"pushedPlayEvents"`
	SyncedArtwork     int      `json:"syncedArtwork"`
	PulledTracks      int      `json:"pulledTracks"`
	SkippedTracks     int      `json:"skippedTracks"`
	Paused            bool     `json:"paused"`
	PauseReason       string   `json:"pauseReason,omitempty"`
	FreeSpaceBytes    uint64   `json:"freeSpaceBytes,omitempty"`
	MinFreeSpaceBytes uint64   `json:"minFreeSpaceBytes,omitempty"`
	Errors            []string `json:"errors,omitempty"`
}

func (a *App) AutoSyncPairedDevices() (SyncAutoResult, error) {
	ctx := context.Background()
	if a != nil && a.ctx != nil {
		ctx = a.ctx
	}
	cachePolicy := syncCachePolicy()
	if cachePolicy == "selective" {
		if _, err := pruneSelectiveSyncCacheIfNeeded(); err != nil {
			return SyncAutoResult{}, err
		}
	} else {
		if result, ok, err := syncFreeSpacePauseResult(); err != nil || ok {
			return result, err
		}
	}
	devices, err := a.ListSyncDevices()
	if err != nil {
		return SyncAutoResult{}, err
	}
	localDeviceID := ensureSyncDeviceID()
	events, err := loadSyncPlayEvents()
	if err != nil {
		return SyncAutoResult{}, err
	}
	localEvents := filterSyncPlayEventsByDevice(events, localDeviceID)
	result := SyncAutoResult{}
	for _, device := range devices {
		if !device.Paired || strings.TrimSpace(device.BaseURL) == "" {
			continue
		}
		result.CheckedDevices++
		identity, err := fetchSyncIdentity(ctx, device.BaseURL)
		if err != nil {
			result.FailedDevices++
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", device.DeviceID, err))
			continue
		}
		token, err := loadSyncAuthTokenForDevice(identity.DeviceID)
		if err != nil {
			result.FailedDevices++
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", identity.DeviceID, err))
			continue
		}
		if len(localEvents) > 0 {
			accepted, err := pushSyncPlayEvents(ctx, device.BaseURL, token, localDeviceID, localEvents)
			if err != nil {
				result.FailedDevices++
				result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", identity.DeviceID, err))
				continue
			}
			result.PushedPlayEvents += accepted
		}
		if syncPeerSupportsLibraryAutoPull(identity) {
			_ = refreshSingleSyncRemoteCatalog(ctx, SyncDeviceRecord{
				DeviceID:    identity.DeviceID,
				DisplayName: identity.DisplayName,
				BaseURL:     device.BaseURL,
				Roles:       identity.Roles,
				Paired:      true,
			}, token)
			if cachePolicy == "selective" {
				pullResult, err := a.PrefetchSyncTracks(recentRemoteSyncTrackRefs(1))
				if err != nil {
					result.FailedDevices++
					result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", identity.DeviceID, err))
					continue
				}
				result.PulledTracks += pullResult.Downloaded
				result.SkippedTracks += pullResult.Skipped
				if pullResult.Failed > 0 {
					result.Errors = append(result.Errors, pullResult.Errors...)
				}
			} else {
				pullResult, err := a.PullSyncLibraryAssets(device.BaseURL, 0)
				if err != nil {
					result.FailedDevices++
					result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", identity.DeviceID, err))
					continue
				}
				result.PulledTracks += pullResult.Downloaded
				result.SkippedTracks += pullResult.Skipped
				if pullResult.Failed > 0 {
					result.Errors = append(result.Errors, pullResult.Errors...)
				}
			}
		}
		artworkCount, err := syncMissingArtworkFromPeer(ctx, device.BaseURL, token, identity.DeviceID)
		if err != nil {
			result.FailedDevices++
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", identity.DeviceID, err))
			continue
		}
		result.SyncedArtwork += artworkCount
		result.SyncedDevices++
	}
	return result, nil
}

func syncPeerSupportsLibraryAutoPull(identity syncIdentityResponse) bool {
	for _, role := range identity.Roles {
		if strings.EqualFold(strings.TrimSpace(role), "LibraryHost") {
			return true
		}
	}
	return false
}

func (a *App) startSyncAutoLoop() {
	if a == nil {
		return
	}
	go func() {
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		for {
			<-timer.C
			result, err := a.AutoSyncPairedDevices()
			if a.ctx != nil && (err != nil || result.CheckedDevices > 0) {
				wailsRuntime.EventsEmit(a.ctx, "ux-sync-auto-result", result)
			}
			timer.Reset(60 * time.Second)
		}
	}()
}

func syncFreeSpacePauseResult() (SyncAutoResult, bool, error) {
	minBytes := syncMinFreeSpaceBytes()
	if minBytes == 0 {
		return SyncAutoResult{}, false, nil
	}
	freeBytes, err := syncAvailableFreeSpaceBytes(config.GetUserDataPath())
	if err != nil {
		return SyncAutoResult{}, false, err
	}
	if freeBytes >= minBytes {
		return SyncAutoResult{}, false, nil
	}
	return SyncAutoResult{
		Paused:            true,
		PauseReason:       "free-space-below-limit",
		FreeSpaceBytes:    freeBytes,
		MinFreeSpaceBytes: minBytes,
		Errors:            []string{"sync paused because free space is below the configured safety limit"},
	}, true, nil
}

func ensureSyncFreeSpaceAvailable() error {
	minBytes := syncMinFreeSpaceBytes()
	if minBytes == 0 {
		return nil
	}
	freeBytes, err := syncAvailableFreeSpaceBytes(config.GetUserDataPath())
	if err != nil {
		return err
	}
	if freeBytes < minBytes {
		return fmt.Errorf("sync paused because free space is below safety limit: free=%d min=%d", freeBytes, minBytes)
	}
	return nil
}

func syncMinFreeSpaceBytes() uint64 {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return 0
	}
	gb := syncSettingFloat64(settings[syncMinFreeSpaceGBSettingsKey])
	if gb <= 0 {
		return 0
	}
	return uint64(gb * 1024 * 1024 * 1024)
}

func syncSettingFloat64(raw interface{}) float64 {
	switch value := raw.(type) {
	case float64:
		return value
	case float32:
		return float64(value)
	case int:
		return float64(value)
	case int64:
		return float64(value)
	case json.Number:
		n, _ := value.Float64()
		return n
	case string:
		var parsed float64
		if _, err := fmt.Sscanf(strings.TrimSpace(value), "%f", &parsed); err == nil {
			return parsed
		}
	}
	return 0
}

func recordLocalSyncPlayEvent(song map[string]interface{}, countedAt time.Time) error {
	trackID := firstNonEmpty(syncTrackString(song, "syncSourceTrackId"), syncTrackID(song), syncTrackString(song, "path"))
	if trackID == "" {
		return nil
	}
	deviceID := ensureSyncDeviceID()
	events, err := loadSyncPlayEvents()
	if err != nil {
		return err
	}
	sequence := nextSyncDeviceSequence(events, deviceID)
	durationMs := int64(0)
	if duration, ok := song["duration"].(float64); ok && duration > 0 {
		durationMs = int64(duration * 1000)
	}
	event := uxsync.PlayEvent{
		EventID:          fmt.Sprintf("evt_%s_%d", sanitiseSyncEventIDPart(deviceID), sequence),
		TrackID:          trackID,
		MatchKey:         syncSongMatchKey(song),
		DeviceID:         deviceID,
		DeviceSequence:   sequence,
		PlayedAt:         countedAt,
		CountedAt:        countedAt,
		DurationPlayedMs: durationMs,
		Completed:        true,
	}
	events = uxsync.MergePlayEvents(events, []uxsync.PlayEvent{event})
	return store.Instance.Save(syncPlayEventsStoreName, events)
}

func pushSyncPlayEvents(ctx context.Context, baseURL, token, deviceID string, events []uxsync.PlayEvent) (int, error) {
	payload := syncLibraryEventsRequest{DeviceID: deviceID, PlayEvents: events}
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(baseURL, "/")+"/sync/library/events", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-UX-Music-Sync-Token", token)
	resp, err := syncHTTPClient().Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("sync play events request failed: %s", resp.Status)
	}
	var result syncLibraryEventsResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}
	return result.Accepted, nil
}

func applyIncomingSyncPlayEventsToPlayCounts(events []uxsync.PlayEvent) error {
	if len(events) == 0 {
		return nil
	}
	return recalculateAllSyncPlayCounts()
}

func syncNewPlayEvents(existing, incoming []uxsync.PlayEvent) []uxsync.PlayEvent {
	seen := map[string]bool{}
	for _, event := range existing {
		if key := syncPlayEventIdentity(event); key != "" {
			seen[key] = true
		}
	}
	var fresh []uxsync.PlayEvent
	for _, event := range incoming {
		key := syncPlayEventIdentity(event)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		fresh = append(fresh, event)
	}
	return fresh
}

func syncPlayEventIdentity(event uxsync.PlayEvent) string {
	if id := strings.TrimSpace(event.EventID); id != "" {
		return "event:" + id
	}
	if strings.TrimSpace(event.DeviceID) != "" && event.DeviceSequence > 0 {
		return fmt.Sprintf("device-sequence:%s:%d", strings.TrimSpace(event.DeviceID), event.DeviceSequence)
	}
	return ""
}

func filterSyncPlayEventsByDevice(events []uxsync.PlayEvent, deviceID string) []uxsync.PlayEvent {
	deviceID = strings.TrimSpace(deviceID)
	var filtered []uxsync.PlayEvent
	for _, event := range events {
		if strings.TrimSpace(event.DeviceID) == deviceID {
			filtered = append(filtered, event)
		}
	}
	return filtered
}

func nextSyncDeviceSequence(events []uxsync.PlayEvent, deviceID string) int64 {
	var max int64
	for _, event := range events {
		if strings.TrimSpace(event.DeviceID) == deviceID && event.DeviceSequence > max {
			max = event.DeviceSequence
		}
	}
	return max + 1
}

func syncLibraryPathByTrackID() map[string]string {
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return map[string]string{}
	}
	paths := map[string]string{}
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		path := syncTrackString(song, "path")
		if path == "" {
			continue
		}
		for _, id := range []string{syncTrackID(song), syncTrackString(song, "syncSourceTrackId"), path} {
			if strings.TrimSpace(id) != "" {
				paths[id] = path
			}
		}
	}
	return paths
}

func syncLibraryPathByMatchKey() map[string]string {
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return map[string]string{}
	}
	paths := map[string]string{}
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		path := syncTrackString(song, "path")
		key := syncSongMatchKey(song)
		if path != "" && key != "" {
			paths[key] = path
		}
	}
	return paths
}

func syncSongMatchKey(song map[string]interface{}) string {
	artist := normaliseSyncSongMatchText(syncTrackString(song, "artist"))
	album := normaliseSyncSongMatchText(syncTrackString(song, "album"))
	title := normaliseSyncSongMatchText(syncTrackString(song, "title"))
	duration := syncSongMatchDurationSeconds(song["duration"])
	if artist == "" && album == "" && title == "" {
		title = normaliseSyncSongMatchText(filepath.Base(syncTrackString(song, "path")))
	}
	plain := fmt.Sprintf("%s|%s|%s|%d", artist, album, title, duration)
	sum := sha1.Sum([]byte(plain))
	return fmt.Sprintf("%x", sum[:])
}

func normaliseSyncSongMatchText(value string) string {
	value = norm.NFKC.String(value)
	value = strings.ToLower(value)
	fields := strings.FieldsFunc(strings.TrimSpace(value), unicode.IsSpace)
	return strings.Join(fields, " ")
}

func syncSongMatchDurationSeconds(raw interface{}) int {
	return int(math.Round(syncSettingFloat64(raw)))
}

func recalculateAllSyncPlayCounts() error {
	if err := ensureSyncPlayCountBaseMigrated(); err != nil {
		return err
	}
	base, err := store.Instance.LoadMap(syncPlayCountBaseStoreName)
	if err != nil {
		base = map[string]interface{}{}
	}
	events, err := loadSyncPlayEvents()
	if err != nil {
		return err
	}
	logCounts := syncPlayCountsByResolvedPath(events)
	counts := map[string]interface{}{}
	for path, raw := range base {
		entry := clonePlayCountEntry(raw)
		counts[path] = entry
	}
	for path, playCount := range logCounts {
		entry := normalisePlayCountEntry(counts[path])
		baseCount, _ := entry["count"].(float64)
		entry["count"] = baseCount + float64(playCount.Count)
		history := entry["history"].([]interface{})
		for _, item := range playCount.History {
			history = append(history, item)
		}
		entry["history"] = trimPlayCountHistory(history)
		counts[path] = entry
	}
	return store.Instance.Save("playcounts", counts)
}

func ensureSyncPlayCountBaseMigrated() error {
	migration, err := store.Instance.LoadMap(syncPlayCountBaseMigrationStoreName)
	if err == nil {
		if migrated, _ := migration["migrated"].(bool); migrated {
			return nil
		}
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		counts = map[string]interface{}{}
	}
	events, err := loadSyncPlayEvents()
	if err != nil {
		return err
	}
	logCounts := syncPlayCountsByResolvedPath(events)
	base := map[string]interface{}{}
	for path, raw := range counts {
		entry := clonePlayCountEntry(raw)
		current, _ := entry["count"].(float64)
		if playCount, ok := logCounts[path]; ok {
			current -= float64(playCount.Count)
		}
		if current < 0 {
			current = 0
		}
		entry["count"] = current
		base[path] = entry
	}
	if err := store.Instance.Save(syncPlayCountBaseStoreName, base); err != nil {
		return err
	}
	return store.Instance.Save(syncPlayCountBaseMigrationStoreName, map[string]interface{}{
		"migrated": true,
	})
}

func syncPlayCountsByResolvedPath(events []uxsync.PlayEvent) map[string]uxsync.PlayCount {
	pathByMatchKey := syncLibraryPathByMatchKey()
	pathByTrackID := syncLibraryPathByTrackID()
	counts := map[string]uxsync.PlayCount{}
	for _, event := range uxsync.MergePlayEvents(nil, events) {
		if !syncIsCountedPlay(event) {
			continue
		}
		path := ""
		if key := strings.TrimSpace(event.MatchKey); key != "" {
			path = pathByMatchKey[key]
		}
		if path == "" {
			path = pathByTrackID[strings.TrimSpace(event.TrackID)]
		}
		if path == "" {
			continue
		}
		count := counts[path]
		count.Count++
		count.History = append(count.History, syncPlayEventHistoryTime(event).Format(time.RFC3339))
		counts[path] = count
	}
	return counts
}

func syncIsCountedPlay(event uxsync.PlayEvent) bool {
	return event.Completed || event.DurationPlayedMs >= 30000
}

func syncPlayEventHistoryTime(event uxsync.PlayEvent) time.Time {
	if !event.CountedAt.IsZero() {
		return event.CountedAt
	}
	return event.PlayedAt
}

func normalisePlayCountEntry(raw interface{}) map[string]interface{} {
	entry, _ := raw.(map[string]interface{})
	if entry == nil {
		entry = map[string]interface{}{}
	}
	if _, ok := entry["count"].(float64); !ok {
		entry["count"] = 0.0
	}
	if _, ok := entry["totalDuration"].(float64); !ok {
		entry["totalDuration"] = 0.0
	}
	if _, ok := entry["history"].([]interface{}); !ok {
		entry["history"] = []interface{}{}
	}
	return entry
}

func clonePlayCountEntry(raw interface{}) map[string]interface{} {
	entry := normalisePlayCountEntry(raw)
	clone := map[string]interface{}{}
	for key, value := range entry {
		clone[key] = value
	}
	if history, ok := entry["history"].([]interface{}); ok {
		copied := make([]interface{}, len(history))
		copy(copied, history)
		clone["history"] = copied
	}
	return clone
}

func trimPlayCountHistory(history []interface{}) []interface{} {
	if len(history) <= 100 {
		return history
	}
	return history[len(history)-100:]
}

func sanitiseSyncEventIDPart(value string) string {
	value = strings.TrimSpace(value)
	var b strings.Builder
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			continue
		}
		b.WriteByte('_')
	}
	if b.Len() == 0 {
		return "device"
	}
	return b.String()
}
