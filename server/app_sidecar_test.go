package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/store"
)

// TestPairingRedeem_PersistsDisplayNameForRemoteDeviceList verifies that a
// displayName supplied at /v1/pairing/redeem time (the mobile pairing flow)
// is persisted and later surfaced by ListPairedRemoteDevices, so the
// sidecar target picker UI can show a human-readable name instead of a bare
// deviceID.
func TestPairingRedeem_PersistsDisplayNameForRemoteDeviceList(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()
	secret := newPairingRedeemSecret()

	body, _ := json.Marshal(pairingRedeemRequest{
		Secret:      secret,
		DeviceID:    "dev_named",
		DisplayName: "Yuki's iPhone",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/pairing/redeem", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	pairingRedeemHandler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("redeem status = %d, want 200: %s", rec.Code, rec.Body.String())
	}

	devices := app.ListPairedRemoteDevices()
	found := false
	for _, d := range devices {
		if d.DeviceID == "dev_named" {
			found = true
			if d.DisplayName != "Yuki's iPhone" {
				t.Fatalf("DisplayName = %q, want %q", d.DisplayName, "Yuki's iPhone")
			}
		}
	}
	if !found {
		t.Fatal("dev_named not present in ListPairedRemoteDevices")
	}
}

func TestRemoteStateHandler_SidecarActiveOnlyForTargetDevice(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()
	target := ensureDeviceAuthToken("dev_sidecar_target")
	other := ensureDeviceAuthToken("dev_sidecar_other")

	if err := app.SetSidecarTargetDevice("dev_sidecar_target"); err != nil {
		t.Fatalf("SetSidecarTargetDevice: %v", err)
	}

	ls := &LANServer{app: app}
	handler := corsMiddleware(deviceAuthMiddleware(http.HandlerFunc(ls.remoteStateHandler)))

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/state", nil)
	req.Header.Set("Authorization", "Bearer "+target)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	var status map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	sidecar, _ := status["sidecar"].(map[string]interface{})
	if active, _ := sidecar["active"].(bool); !active {
		t.Fatalf("expected sidecar.active=true for the target device, got %v", sidecar)
	}

	req = httptest.NewRequest(http.MethodGet, "/v1/remote/state", nil)
	req.Header.Set("Authorization", "Bearer "+other)
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	status = nil
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	sidecar, _ = status["sidecar"].(map[string]interface{})
	if active, _ := sidecar["active"].(bool); active {
		t.Fatalf("expected sidecar.active=false for a non-target device, got %v", sidecar)
	}
}

func TestSetSidecarTargetDevice_RejectsUnpairedDevice(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()

	if err := app.SetSidecarTargetDevice("dev_not_paired"); err == nil {
		t.Fatal("expected error setting sidecar target to an unpaired device")
	}
	if got := app.GetSidecarTargetDevice(); got != "" {
		t.Fatalf("target should remain unset after a rejected call, got %q", got)
	}
}

func TestSetSidecarTargetDevice_EmptyStringClears(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()
	ensureDeviceAuthToken("dev_sidecar_clear")

	if err := app.SetSidecarTargetDevice("dev_sidecar_clear"); err != nil {
		t.Fatalf("SetSidecarTargetDevice: %v", err)
	}
	if err := app.SetSidecarTargetDevice(""); err != nil {
		t.Fatalf("SetSidecarTargetDevice(\"\"): %v", err)
	}
	if got := app.GetSidecarTargetDevice(); got != "" {
		t.Fatalf("GetSidecarTargetDevice() = %q, want empty after clearing", got)
	}
}

func TestListPairedRemoteDevices_ReportsOnlineWithinWindow(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()
	token := ensureDeviceAuthToken("dev_list_online")
	ensureDeviceAuthToken("dev_list_never_seen")

	// Drive an authenticated request through the real middleware so
	// last-seen tracking is exercised the way production traffic hits it.
	handler := corsMiddleware(deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})))
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(httptest.NewRecorder(), req)

	devices := app.ListPairedRemoteDevices()
	var online, neverSeen *PairedRemoteDevice
	for i := range devices {
		switch devices[i].DeviceID {
		case "dev_list_online":
			online = &devices[i]
		case "dev_list_never_seen":
			neverSeen = &devices[i]
		}
	}
	if online == nil || !online.Online || online.LastSeenAt == "" {
		t.Fatalf("expected dev_list_online to be reported online with a timestamp, got %+v", online)
	}
	if neverSeen == nil || neverSeen.Online || neverSeen.LastSeenAt != "" {
		t.Fatalf("expected dev_list_never_seen to be offline with no timestamp, got %+v", neverSeen)
	}
}

func TestSidecarTarget_ClearedWhenTargetDeviceUnpaired(t *testing.T) {
	newTempRemoteStore(t)
	app := NewApp()
	ensureDeviceAuthToken("dev_sidecar_unpair")
	if err := app.SetSidecarTargetDevice("dev_sidecar_unpair"); err != nil {
		t.Fatalf("SetSidecarTargetDevice: %v", err)
	}

	// Unpair by removing the token from settings directly (mirrors what an
	// "unpair device" action elsewhere in the app would do).
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("LoadMap: %v", err)
	}
	rawTokens, _ := settings[deviceAuthTokensSettingsKey].(map[string]interface{})
	delete(rawTokens, "dev_sidecar_unpair")
	settings[deviceAuthTokensSettingsKey] = rawTokens
	if err := store.Instance.Save("settings", settings); err != nil {
		t.Fatalf("Save: %v", err)
	}

	directive := app.sidecarDirectiveFor("dev_sidecar_unpair")
	if active, _ := directive["active"].(bool); active {
		t.Fatalf("expected sidecar directive to be inactive once the target device is unpaired, got %v", directive)
	}
	if got := app.GetSidecarTargetDevice(); got != "" {
		t.Fatalf("expected sidecar target to be cleared once the target device is unpaired, got %q", got)
	}
}
