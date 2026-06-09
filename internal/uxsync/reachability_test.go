package uxsync

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestMDNSPeerCandidateBaseURLs_includesAllHostsInOrder(t *testing.T) {
	peer := MDNSPeer{
		Host:  "192.168.1.182",
		Hosts: []string{"192.168.1.182", "192.168.0.226"},
		Port:  8765,
	}

	got := peer.CandidateBaseURLs()

	if len(got) != 2 {
		t.Fatalf("expected two candidates, got %#v", got)
	}
	if got[0] != "http://192.168.1.182:8765" || got[1] != "http://192.168.0.226:8765" {
		t.Fatalf("unexpected candidates: %#v", got)
	}
}

func TestResolveReachablePeer_selectsFirstResponsiveCandidate(t *testing.T) {
	okServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sync/identity" {
			t.Fatalf("unexpected probe path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"role":"ux-music-sync"}`))
	}))
	defer okServer.Close()

	peer := MDNSPeer{
		Host:  "127.0.0.1",
		Hosts: []string{"127.0.0.1"},
		Port:  1,
	}
	peer.Hosts = append(peer.Hosts, hostPortFromURL(t, okServer.URL))

	resolved, err := ResolveReachablePeer(peer, nil)
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
