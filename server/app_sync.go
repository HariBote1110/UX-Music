package server

import (
	"encoding/json"
	"net/http"
	"strings"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

const syncPlayEventsStoreName = "sync-play-events"

type syncLibraryEventsRequest struct {
	DeviceID   string             `json:"deviceId"`
	PlayEvents []uxsync.PlayEvent `json:"playEvents"`
}

type syncLibraryEventsResponse struct {
	Accepted int             `json:"accepted"`
	Ack      uxsync.EventAck `json:"ack"`
}

func registerSyncRoutes(mux *http.ServeMux, _ *App) {
	mux.HandleFunc("/sync/library/events", syncLibraryEventsHandler)
}

func syncLibraryEventsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req syncLibraryEventsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	req.DeviceID = strings.TrimSpace(req.DeviceID)
	normalisePlayEventDevices(req.DeviceID, req.PlayEvents)

	existing, err := loadSyncPlayEvents()
	if err != nil {
		http.Error(w, "failed to load sync play events", http.StatusInternalServerError)
		return
	}

	merged := uxsync.MergePlayEvents(existing, req.PlayEvents)
	if err := store.Instance.Save(syncPlayEventsStoreName, merged); err != nil {
		http.Error(w, "failed to save sync play events", http.StatusInternalServerError)
		return
	}

	writeJSON(w, syncLibraryEventsResponse{
		Accepted: len(req.PlayEvents),
		Ack: uxsync.EventAck{
			DeviceID:          req.DeviceID,
			MaxDeviceSequence: maxDeviceSequence(req.DeviceID, req.PlayEvents),
			AckedEventIDs:     eventIDs(req.PlayEvents),
		},
	})
}

func loadSyncPlayEvents() ([]uxsync.PlayEvent, error) {
	raw, err := store.Instance.Load(syncPlayEventsStoreName)
	if err != nil || raw == nil {
		return []uxsync.PlayEvent{}, err
	}
	bytes, err := json.Marshal(raw)
	if err != nil {
		return nil, err
	}
	var events []uxsync.PlayEvent
	if err := json.Unmarshal(bytes, &events); err != nil {
		return nil, err
	}
	return events, nil
}

func normalisePlayEventDevices(deviceID string, events []uxsync.PlayEvent) {
	if deviceID == "" {
		return
	}
	for i := range events {
		if strings.TrimSpace(events[i].DeviceID) == "" {
			events[i].DeviceID = deviceID
		}
	}
}

func maxDeviceSequence(deviceID string, events []uxsync.PlayEvent) int64 {
	var max int64
	for _, event := range events {
		if deviceID != "" && event.DeviceID != deviceID {
			continue
		}
		if event.DeviceSequence > max {
			max = event.DeviceSequence
		}
	}
	return max
}

func eventIDs(events []uxsync.PlayEvent) []string {
	ids := make([]string, 0, len(events))
	for _, event := range events {
		id := strings.TrimSpace(event.EventID)
		if id != "" {
			ids = append(ids, id)
		}
	}
	return ids
}
