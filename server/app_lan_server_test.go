package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"ux-music-sidecar/internal/uxsync"
)

func TestStartLANServerHopsWhenPreferredPortIsOccupied(t *testing.T) {
	listeners, ports := occupyConsecutivePorts(t, 2)
	defer closeListeners(listeners)

	preferred := ports[0]
	second := ports[1]
	listeners[1].Close()
	withLANServerTestSeams(t, []int{preferred, second}, nil, noOpAdvertiseMDNS)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lan := StartLANServer(ctx, &App{})
	defer lan.server.Close()

	status := GetLANServerStatus()
	if !status.Listening || status.Port != second {
		t.Fatalf("expected server to hop to %d, got %#v", second, status)
	}
	if status.PreferredPort != lanServerPreferredPort || !status.Hopped || status.Error != "" {
		t.Fatalf("unexpected hopped status: %#v", status)
	}
	if got := portFromAddress(t, GetLANServerAddress()); got != second {
		t.Fatalf("GetLANServerAddress port=%d, want %d", got, second)
	}

	pairing, err := url.Parse(BuildPairingURL())
	if err != nil {
		t.Fatalf("parse pairing URL: %v", err)
	}
	if got := pairing.Query().Get("port"); got != strconv.Itoa(second) {
		t.Fatalf("pairing URL port=%q, want %d", got, second)
	}
}

func TestStartLANServerAllCandidatesFailDoesNotAdvertiseMDNS(t *testing.T) {
	listeners, ports := occupyConsecutivePorts(t, 3)
	defer closeListeners(listeners)

	advertiseCalls := 0
	advertise := func(uxsync.MDNSAdvertiseInfo, int) (*uxsync.MDNSAdvertisement, error) {
		advertiseCalls++
		return nil, nil
	}
	withLANServerTestSeams(t, ports, nil, advertise)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lan := StartLANServer(ctx, &App{})
	defer lan.server.Close()

	status := GetLANServerStatus()
	if status.Listening || status.Port != 0 || status.Hopped {
		t.Fatalf("expected failed LAN server status, got %#v", status)
	}
	if status.PreferredPort != lanServerPreferredPort {
		t.Fatalf("preferred port=%d, want %d", status.PreferredPort, lanServerPreferredPort)
	}
	if status.Error == "" || !strings.Contains(status.Error, strconv.Itoa(ports[0])) || !strings.Contains(status.Error, strconv.Itoa(ports[2])) {
		t.Fatalf("error should list tried ports, got %q", status.Error)
	}
	if GetLANServerAddress() != "" || status.Address != "" {
		t.Fatalf("failed server must not expose an address: status=%#v address=%q", status, GetLANServerAddress())
	}
	if advertiseCalls != 0 {
		t.Fatalf("mDNS must not be started after bind failure, calls=%d", advertiseCalls)
	}
}

func TestGetLANServerStatusJSONShape(t *testing.T) {
	status := LANServerStatus{
		Listening:     true,
		Port:          8766,
		PreferredPort: 8765,
		Hopped:        true,
		Error:         "",
		Address:       "192.168.1.2:8766",
	}
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatalf("marshal status: %v", err)
	}
	got := string(raw)
	for _, field := range []string{`"listening"`, `"port"`, `"preferredPort"`, `"hopped"`, `"error"`, `"address"`} {
		if !strings.Contains(got, field) {
			t.Fatalf("status JSON missing %s: %s", field, got)
		}
	}
}

func noOpAdvertiseMDNS(uxsync.MDNSAdvertiseInfo, int) (*uxsync.MDNSAdvertisement, error) {
	return nil, nil
}

func withLANServerTestSeams(t *testing.T, ports []int, listenFunc func(string, string) (net.Listener, error), advertiseFunc func(uxsync.MDNSAdvertiseInfo, int) (*uxsync.MDNSAdvertisement, error)) {
	t.Helper()
	// StartLANServer advertises mDNS via ensureSyncDeviceID, which persists
	// settings; keep that write out of the package directory.
	newTempSyncStore(t)
	oldPorts := lanServerCandidatePortsFunc
	oldListen := lanServerListenFunc
	oldAdvertise := advertiseMDNSFunc
	lanServerCandidatePortsFunc = func() []int { return append([]int(nil), ports...) }
	if listenFunc != nil {
		lanServerListenFunc = listenFunc
	}
	if advertiseFunc != nil {
		advertiseMDNSFunc = advertiseFunc
	}
	t.Cleanup(func() {
		lanServerCandidatePortsFunc = oldPorts
		lanServerListenFunc = oldListen
		advertiseMDNSFunc = oldAdvertise
	})
}

func occupyConsecutivePorts(t *testing.T, count int) ([]net.Listener, []int) {
	t.Helper()
	for attempt := 0; attempt < 100; attempt++ {
		probe, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("find test port: %v", err)
		}
		firstPort := probe.Addr().(*net.TCPAddr).Port
		probe.Close()

		listeners := make([]net.Listener, 0, count)
		ports := make([]int, 0, count)
		ok := true
		for i := 0; i < count; i++ {
			listener, listenErr := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", firstPort+i))
			if listenErr != nil {
				ok = false
				break
			}
			listeners = append(listeners, listener)
			ports = append(ports, firstPort+i)
		}
		if ok {
			return listeners, ports
		}
		closeListeners(listeners)
	}
	t.Fatal("could not reserve consecutive test ports")
	return nil, nil
}

func closeListeners(listeners []net.Listener) {
	for _, listener := range listeners {
		if listener != nil {
			_ = listener.Close()
		}
	}
}

func portFromAddress(t *testing.T, address string) int {
	t.Helper()
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("split address %q: %v", address, err)
	}
	value, err := strconv.Atoi(port)
	if err != nil {
		t.Fatalf("parse address port %q: %v", port, err)
	}
	return value
}
