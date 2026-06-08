package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type SyncAutoResult struct {
	CheckedDevices   int      `json:"checkedDevices"`
	SyncedDevices    int      `json:"syncedDevices"`
	FailedDevices    int      `json:"failedDevices"`
	PushedPlayEvents int      `json:"pushedPlayEvents"`
	Errors           []string `json:"errors,omitempty"`
}

func (a *App) AutoSyncPairedDevices() (SyncAutoResult, error) {
	ctx := context.Background()
	if a != nil && a.ctx != nil {
		ctx = a.ctx
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
		result.SyncedDevices++
	}
	return result, nil
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
	pathByTrackID := syncLibraryPathByTrackID()
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		counts = map[string]interface{}{}
	}
	for trackID, playCount := range uxsync.PlayCountsByTrack(events) {
		if playCount.Count <= 0 {
			continue
		}
		key := firstNonEmpty(pathByTrackID[trackID], trackID)
		entry := normalisePlayCountEntry(counts[key])
		entry["count"] = entry["count"].(float64) + float64(playCount.Count)
		history := entry["history"].([]interface{})
		for _, item := range playCount.History {
			history = append(history, item)
		}
		entry["history"] = trimPlayCountHistory(history)
		counts[key] = entry
	}
	return store.Instance.Save("playcounts", counts)
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
