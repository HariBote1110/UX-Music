package uxsync

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// handlerObserver は httptest ハンドラーゴルーチンからの観測結果を溜める。
// ハンドラー内で t.Fatalf を呼ぶと FailNow がテスト外ゴルーチンで走り、応答を
// 返さないままハンドラーが終了して無関係な失敗に化けるため、記録だけ行い
// テストゴルーチン側で assertNoErrors する。
type handlerObserver struct {
	mu     sync.Mutex
	errors []string
}

func (o *handlerObserver) errorf(format string, args ...interface{}) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.errors = append(o.errors, fmt.Sprintf(format, args...))
}

func (o *handlerObserver) assertNoErrors(t *testing.T) {
	t.Helper()
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.errors) == 0 {
		return
	}
	for _, message := range o.errors {
		t.Errorf("handler goroutine: %s", message)
	}
	t.FailNow()
}

func TestMDNSPeerCandidateBaseURLs_includesAllHostsInOrder(t *testing.T) {
	peer := MDNSPeer{
		Host:  "192.168.1.182",
		Hosts: []string{"192.168.1.182", "192.168.0.226"},
		Port:  8765,
	}

	got := peer.CandidateBaseURLs()

	if len(got) != 20 {
		t.Fatalf("expected stored port plus ten fallback ports for two hosts, got %#v", got)
	}
	if got[0] != "http://192.168.1.182:8765" || got[1] != "http://192.168.0.226:8765" || got[2] != "http://192.168.1.182:8766" {
		t.Fatalf("unexpected candidate order: %#v", got[:3])
	}
}

func TestResolveReachablePeer_selectsFirstResponsiveCandidate(t *testing.T) {
	observer := &handlerObserver{}
	okServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/identity" {
			observer.errorf("unexpected probe path: %s", r.URL.Path)
			http.Error(w, "unexpected probe path", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"deviceId":"dev_ok","role":"ux-music-sync"}`))
	}))
	defer okServer.Close()

	peer := MDNSPeer{
		DeviceID: "dev_ok",
		Host:     "127.0.0.1",
		Hosts:    []string{"127.0.0.1"},
		Port:     1,
	}
	peer.Hosts = append(peer.Hosts, hostPortFromURL(t, okServer.URL))

	resolved, err := ResolveReachablePeer(peer, nil)
	observer.assertNoErrors(t)
	if err != nil {
		t.Fatalf("expected reachable peer: %v", err)
	}
	if resolved.ReachableBaseURL != okServer.URL {
		t.Fatalf("expected %s, got %s", okServer.URL, resolved.ReachableBaseURL)
	}
}

func hostPortFromURL(t *testing.T, raw string) string {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	return u.Host
}

func TestResolveReachablePeerFallsBackToCandidatePortWhenDeviceIDMatches(t *testing.T) {
	identityServer, port := identityServerOnLoopback(t, "dev_expected")
	defer identityServer.Close()
	withCandidatePorts(t, []int{port})

	peer := MDNSPeer{DeviceID: "dev_expected", Host: "127.0.0.1", Hosts: []string{"127.0.0.1"}, Port: 1}
	resolved, err := ResolveReachablePeer(peer, &http.Client{Timeout: 150 * time.Millisecond})
	if err != nil {
		t.Fatalf("expected fallback to recover peer: %v", err)
	}
	if resolved.ReachableBaseURL != "http://127.0.0.1:"+strconv.Itoa(port) {
		t.Fatalf("unexpected reachable URL: %q", resolved.ReachableBaseURL)
	}
}

func TestResolveReachablePeerRejectsFallbackWithDifferentDeviceID(t *testing.T) {
	identityServer, port := identityServerOnLoopback(t, "dev_other")
	defer identityServer.Close()
	withCandidatePorts(t, []int{port})

	peer := MDNSPeer{DeviceID: "dev_expected", Host: "127.0.0.1", Hosts: []string{"127.0.0.1"}, Port: 1}
	_, err := ResolveReachablePeer(peer, &http.Client{Timeout: 150 * time.Millisecond})
	if err == nil || !strings.Contains(err.Error(), "device id") {
		t.Fatalf("expected device ID mismatch error, got %v", err)
	}
}

func TestResolveReachablePeerDoesNotProbeFallbackPortsWithoutDeviceID(t *testing.T) {
	var probeCount int
	var probeMu sync.Mutex
	identityServer, port := identityServerOnLoopbackWithHandler(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		probeMu.Lock()
		probeCount++
		probeMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"deviceId":"unexpected"}`))
	}))
	defer identityServer.Close()
	withCandidatePorts(t, []int{port})

	peer := MDNSPeer{Host: "127.0.0.1", Hosts: []string{"127.0.0.1"}, Port: 1}
	_, err := ResolveReachablePeer(peer, &http.Client{Timeout: 150 * time.Millisecond})
	if err == nil {
		t.Fatal("expected unresolved peer without an expected device ID")
	}
	probeMu.Lock()
	got := probeCount
	probeMu.Unlock()
	if got != 0 {
		t.Fatalf("fallback port was probed without an expected device ID: %d requests", got)
	}
}

func TestResolveReachablePeerAcceptsStoredPortForAnySuccessfulIdentityResponse(t *testing.T) {
	identityServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer identityServer.Close()
	storedPort := mustPortFromURL(t, identityServer.URL)
	withCandidatePorts(t, nil)

	peer := MDNSPeer{
		DeviceID: "dev_expected",
		Host:     "127.0.0.1",
		Hosts:    []string{"127.0.0.1"},
		Port:     storedPort,
	}
	resolved, err := ResolveReachablePeer(peer, &http.Client{Timeout: 150 * time.Millisecond})
	if err != nil {
		t.Fatalf("stored port should accept a successful identity response without a device ID: %v", err)
	}
	if resolved.ReachableBaseURL != identityServer.URL {
		t.Fatalf("unexpected reachable URL: %q", resolved.ReachableBaseURL)
	}
}

func TestResolveReachablePeersRunsConcurrentlyAndPreservesOrder(t *testing.T) {
	const (
		peerCount = 4
		timeout   = 120 * time.Millisecond
	)
	withCandidatePorts(t, nil)
	peers := make([]MDNSPeer, 0, peerCount)
	servers := make([]*httptest.Server, 0, peerCount)
	for index := 0; index < peerCount; index++ {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			<-r.Context().Done()
		}))
		servers = append(servers, server)
		port := mustPortFromURL(t, server.URL)
		peers = append(peers, MDNSPeer{
			DeviceID: fmt.Sprintf("dev_%d", index),
			Host:     "127.0.0.1",
			Hosts:    []string{"127.0.0.1"},
			Port:     port,
		})
	}
	for _, server := range servers {
		defer server.Close()
	}

	started := time.Now()
	resolved := ResolveReachablePeers(peers, &http.Client{Timeout: timeout})
	elapsed := time.Since(started)
	if elapsed > 2*timeout {
		t.Fatalf("peer probes were sequential: elapsed=%v timeout=%v", elapsed, timeout)
	}
	if len(resolved) != len(peers) {
		t.Fatalf("resolved peer count=%d, want %d", len(resolved), len(peers))
	}
	for index := range peers {
		if resolved[index].DeviceID != peers[index].DeviceID {
			t.Fatalf("resolved peer order changed at index %d: got %q want %q", index, resolved[index].DeviceID, peers[index].DeviceID)
		}
	}
}

func identityServerOnLoopback(t *testing.T, deviceID string) (*httptest.Server, int) {
	return identityServerOnLoopbackWithHandler(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"deviceId":"` + deviceID + `"}`))
	}))
}

func identityServerOnLoopbackWithHandler(t *testing.T, handler http.Handler) (*httptest.Server, int) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen identity server: %v", err)
	}
	identityServer := httptest.NewUnstartedServer(handler)
	identityServer.Listener = listener
	identityServer.Start()
	return identityServer, listener.Addr().(*net.TCPAddr).Port
}

func mustPortFromURL(t *testing.T, raw string) int {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil {
		t.Fatalf("parse server port: %v", err)
	}
	return port
}

func withCandidatePorts(t *testing.T, ports []int) {
	t.Helper()
	old := syncCandidatePortsFunc
	syncCandidatePortsFunc = func() []int { return append([]int(nil), ports...) }
	t.Cleanup(func() { syncCandidatePortsFunc = old })
}
