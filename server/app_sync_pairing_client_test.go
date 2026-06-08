package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
)

func TestStartSyncPairingCallsRemotePeerWithLocalDeviceID(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{syncDeviceIDSettingsKey: "dev_local_mac"}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	var observedDeviceID string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, map[string]interface{}{
				"deviceId":    "dev_remote_pc",
				"displayName": "mainPC",
				"roles":       []string{"LibraryHost"},
			})
		case "/sync/pairing/start":
			var req syncPairingStartRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode start request: %v", err)
			}
			observedDeviceID = req.DeviceID
			writeJSON(w, syncPairingStartResponse{
				SessionID: "sess_remote_1",
				DeviceID:  req.DeviceID,
				Code:      "123456",
				ExpiresAt: "2026-06-08T12:02:00Z",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	started, err := (&App{}).StartSyncPairing(remote.URL + "/")
	if err != nil {
		t.Fatalf("start sync pairing: %v", err)
	}

	if observedDeviceID != "dev_local_mac" {
		t.Fatalf("expected local device id in remote request, got %q", observedDeviceID)
	}
	if started.BaseURL != remote.URL || started.RemoteDeviceID != "dev_remote_pc" || started.RemoteDisplayName != "mainPC" {
		t.Fatalf("unexpected remote identity in response: %#v", started)
	}
	if started.SessionID != "sess_remote_1" || started.Code != "123456" || started.LocalDeviceID != "dev_local_mac" {
		t.Fatalf("unexpected pairing start response: %#v", started)
	}
}

func TestConfirmSyncPairingStoresRemoteIssuedTokenForRemoteDevice(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{syncDeviceIDSettingsKey: "dev_local_mac"}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, map[string]interface{}{
				"deviceId":    "dev_remote_pc",
				"displayName": "mainPC",
			})
		case "/sync/pairing/confirm":
			var req syncPairingConfirmRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode confirm request: %v", err)
			}
			if req.SessionID != "sess_remote_1" || req.Code != "123456" {
				t.Fatalf("unexpected confirm request: %#v", req)
			}
			writeJSON(w, syncPairingConfirmResponse{
				DeviceID: "dev_local_mac",
				Token:    "tok_remote_for_local",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	confirmed, err := (&App{}).ConfirmSyncPairing(remote.URL, "sess_remote_1", "123456", "dev_remote_pc")
	if err != nil {
		t.Fatalf("confirm sync pairing: %v", err)
	}
	if confirmed.RemoteDeviceID != "dev_remote_pc" || confirmed.RemoteDisplayName != "mainPC" || !confirmed.TokenSaved {
		t.Fatalf("unexpected confirm response: %#v", confirmed)
	}

	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if rawTokens["dev_remote_pc"] != "tok_remote_for_local" {
		t.Fatalf("expected token to be stored for remote device, got %#v", rawTokens)
	}
}

func TestConfirmSyncPairingRejectsChangedRemoteDevice(t *testing.T) {
	newTempSyncStore(t)

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, map[string]interface{}{
				"deviceId":    "dev_other_pc",
				"displayName": "Unexpected PC",
			})
		case "/sync/pairing/confirm":
			writeJSON(w, syncPairingConfirmResponse{
				DeviceID: "dev_local_mac",
				Token:    "tok_remote_for_local",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	_, err := (&App{}).ConfirmSyncPairing(remote.URL, "sess_remote_1", "123456", "dev_remote_pc")
	if err == nil {
		t.Fatal("expected changed remote device to be rejected")
	}

	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if len(rawTokens) != 0 {
		t.Fatalf("expected no token to be stored, got %#v", rawTokens)
	}
}
