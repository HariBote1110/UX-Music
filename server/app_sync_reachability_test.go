package server

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"

	"ux-music-sidecar/internal/store"
)

func TestListSyncDevicesDoesNotProbeKnownPeers(t *testing.T) {
	newTempSyncStore(t)
	var probeCount int
	var probeMu sync.Mutex
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		probeMu.Lock()
		probeCount++
		probeMu.Unlock()
		writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote", ProtocolVersion: syncProtocolVersion})
	}))
	defer remote.Close()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{
			DeviceID: "dev_remote",
			BaseURL:  remote.URL,
		}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	if _, err := (&App{}).ListSyncDevices(); err != nil {
		t.Fatalf("list sync devices: %v", err)
	}
	probeMu.Lock()
	got := probeCount
	probeMu.Unlock()
	if got != 0 {
		t.Fatalf("ListSyncDevices performed %d network probes", got)
	}
}

func TestSyncContactRecoversAndPersistsStalePeerPort(t *testing.T) {
	newTempSyncStore(t)
	const (
		preferredPort = 8765
		fallbackPort  = 8766
		remoteID      = "dev_remote"
	)
	listener, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(fallbackPort))
	if err != nil {
		t.Skipf("candidate port %d is unavailable: %v", fallbackPort, err)
	}
	remote := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: remoteID, ProtocolVersion: syncProtocolVersion})
		default:
			http.NotFound(w, r)
		}
	}))
	remote.Listener = listener
	remote.Start()
	defer remote.Close()

	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:     "dev_local",
		deviceAuthTokensSettingsKey: map[string]interface{}{remoteID: "tok_remote"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{
			DeviceID: remoteID,
			BaseURL:  "http://127.0.0.1:" + strconv.Itoa(preferredPort),
		}},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	devices, err := (&App{}).ListSyncDevices()
	if err != nil {
		t.Fatalf("list sync devices: %v", err)
	}
	if len(devices) != 1 || devices[0].BaseURL != "http://127.0.0.1:"+strconv.Itoa(preferredPort) {
		t.Fatalf("ListSyncDevices should keep the stored URL, got %#v", devices)
	}

	if _, err := (&App{}).AutoSyncPairedDevices(); err != nil {
		t.Fatalf("auto sync: %v", err)
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	known := decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey])
	if len(known) != 1 || known[0].BaseURL != remote.URL {
		raw, _ := json.Marshal(known)
		t.Fatalf("expected recovered base URL to be persisted, got %s", raw)
	}
}
