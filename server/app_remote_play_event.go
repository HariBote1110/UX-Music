package server

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

// remotePlayEventRequest is the body of POST /v1/remote/play-event: a
// lightweight client (e.g. a future Apple TV app) reporting a completed
// play without joining desktop-to-desktop sync as a peer.
type remotePlayEventRequest struct {
	TrackID           string  `json:"trackId"`
	PlayedAt          string  `json:"playedAt"`
	DurationPlayedSec float64 `json:"durationPlayedSec,omitempty"`
}

// remotePlayEventResponse confirms how the reported play was resolved and
// folded into the existing play-count convergence machinery.
type remotePlayEventResponse struct {
	TrackID  string `json:"trackId"`
	MatchKey string `json:"matchKey"`
	Count    int    `json:"count"`
}

// remotePlayEventHandler resolves trackId against the local library, builds
// a uxsync.PlayEvent consistent with locally recorded plays (see
// recordLocalSyncPlayEvent in app_sync_auto.go), and folds it into the same
// sync-play-events store / playcounts recalculation / play-counts-updated
// emit used by every other play-count path. See progress/remote-play-event.md
// for why the host's own device identity is used and how idempotency works.
func (a *App) remotePlayEventHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req remotePlayEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	trackID := strings.TrimSpace(req.TrackID)
	if trackID == "" {
		writeAPIError(w, "missing trackId", http.StatusBadRequest)
		return
	}
	playedAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.PlayedAt))
	if err != nil {
		writeAPIError(w, "invalid or missing playedAt (expected RFC3339)", http.StatusBadRequest)
		return
	}

	song, ok := remoteLibrarySongByID(trackID)
	if !ok {
		writeAPIError(w, "unknown trackId", http.StatusNotFound)
		return
	}
	matchKey := syncSongMatchKey(song)

	// The host's own device identity is used for the derived PlayEvent, not a
	// caller-derived id: a remote-play-event report is the host recording a
	// completed play on its own library, exactly like a locally triggered
	// play (recordLocalSyncPlayEvent). This keeps the event on the host's
	// existing outbox sequence so it propagates to other sync peers via the
	// same flushSyncPlayEventsToReachablePeers path, with no new per-caller
	// device identity or token-to-device mapping to invent.
	deviceID := ensureSyncDeviceID()

	existing, err := loadSyncPlayEvents()
	if err != nil {
		writeAPIError(w, "failed to load sync play events", http.StatusInternalServerError)
		return
	}

	durationMs := int64(0)
	if req.DurationPlayedSec > 0 {
		durationMs = int64(req.DurationPlayedSec * 1000)
	}
	event := uxsync.PlayEvent{
		EventID:          remotePlayEventID(deviceID, trackID, playedAt),
		TrackID:          trackID,
		MatchKey:         matchKey,
		DeviceID:         deviceID,
		DeviceSequence:   nextSyncDeviceSequence(existing, deviceID),
		PlayedAt:         playedAt,
		CountedAt:        time.Now().UTC(),
		DurationPlayedMs: durationMs,
		Completed:        true,
	}

	merged := uxsync.MergePlayEvents(existing, []uxsync.PlayEvent{event})
	if err := store.Instance.Save(syncPlayEventsStoreName, merged); err != nil {
		writeAPIError(w, "failed to save sync play events", http.StatusInternalServerError)
		return
	}
	if err := recalculateAllSyncPlayCounts(); err != nil {
		writeAPIError(w, "failed to apply play counts", http.StatusInternalServerError)
		return
	}
	a.emitPlayCountsUpdated()

	writeJSON(w, remotePlayEventResponse{
		TrackID:  trackID,
		MatchKey: matchKey,
		Count:    remotePlayEventCountForSong(song),
	})
}

// remotePlayEventID derives a deterministic event id from the request's own
// content (device identity + trackId + playedAt) so that redelivering the
// exact same report is idempotent: uxsync.MergePlayEvents dedups by EventID,
// and the request schema (trackId/playedAt/durationPlayedSec) carries no
// client-generated event id of its own to reuse instead.
func remotePlayEventID(deviceID, trackID string, playedAt time.Time) string {
	sum := sha1.Sum([]byte(deviceID + "|" + trackID + "|" + playedAt.UTC().Format(time.RFC3339)))
	return "evt_remote_" + hex.EncodeToString(sum[:])
}

func remotePlayEventCountForSong(song map[string]interface{}) int {
	path := syncTrackString(song, "path")
	if path == "" {
		return 0
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		return 0
	}
	entry, _ := counts[path].(map[string]interface{})
	if entry == nil {
		return 0
	}
	count, _ := entry["count"].(float64)
	return int(count)
}
