package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

func TestRunSyncCLIPairStoresTokenAndKnownPeer(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey: "dev_crescent",
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	var confirmed bool
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{
				DeviceID:        "dev_mac_mini",
				DisplayName:     "YukinoMac-mini",
				ProtocolVersion: syncProtocolVersion,
				Roles:           []string{"LibraryHost"},
			})
		case "/sync/pairing/start":
			writeJSON(w, syncPairingStartResponse{
				SessionID: "sess_mac_1",
				DeviceID:  "dev_crescent",
				Code:      "123456",
				ExpiresAt: "2026-06-09T09:45:00Z",
			})
		case "/sync/pairing/confirm":
			var req syncPairingConfirmRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode confirm request: %v", err)
			}
			if req.SessionID != "sess_mac_1" || req.Code != "123456" {
				t.Fatalf("unexpected confirm request: %#v", req)
			}
			confirmed = true
			writeJSON(w, syncPairingConfirmResponse{
				DeviceID: "dev_crescent",
				Token:    "tok_mac_for_crescent",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	handled, err := RunSyncCLI([]string{"--sync-pair", remote.URL})
	if err != nil {
		t.Fatalf("sync pair cli: %v", err)
	}
	if !handled || !confirmed {
		t.Fatalf("expected CLI to handle and confirm pairing handled=%v confirmed=%v", handled, confirmed)
	}

	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	tokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if tokens["dev_mac_mini"] != "tok_mac_for_crescent" {
		t.Fatalf("expected Mac token to be saved, got %#v", tokens)
	}
	known := decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey])
	if len(known) != 1 || known[0].DeviceID != "dev_mac_mini" || known[0].BaseURL != remote.URL {
		t.Fatalf("expected known Mac peer to be saved, got %#v", known)
	}
}

func TestRunSyncCLIAutoOnceRunsAutoSyncPairedDevices(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_crescent",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_mac_mini": "tok_mac"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save(syncPlayEventsStoreName, []uxsync.PlayEvent{{
		EventID:          "evt_crescent_1",
		TrackID:          "mac-track-1",
		DeviceID:         "dev_crescent",
		DeviceSequence:   1,
		DurationPlayedMs: 180000,
		Completed:        true,
	}}); err != nil {
		t.Fatalf("seed events: %v", err)
	}

	var observedEvents []uxsync.PlayEvent
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_mac_mini", DisplayName: "YukinoMac-mini", ProtocolVersion: syncProtocolVersion})
		case "/sync/library/events":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_mac" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			var req syncLibraryEventsRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode events: %v", err)
			}
			observedEvents = req.PlayEvents
			writeJSON(w, syncLibraryEventsResponse{Accepted: len(req.PlayEvents), Ack: uxsync.EventAck{DeviceID: req.DeviceID, MaxDeviceSequence: 1}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_crescent",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_mac_mini": "tok_mac"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_mac_mini", DisplayName: "YukinoMac-mini", BaseURL: remote.URL}},
	}); err != nil {
		t.Fatalf("seed known peer: %v", err)
	}

	handled, err := RunSyncCLI([]string{"--sync-auto-once"})
	if err != nil {
		t.Fatalf("sync auto once cli: %v", err)
	}
	if !handled {
		t.Fatal("expected CLI to handle --sync-auto-once")
	}
	if len(observedEvents) != 1 || observedEvents[0].EventID != "evt_crescent_1" {
		t.Fatalf("expected one pushed play event, got %#v", observedEvents)
	}
}
