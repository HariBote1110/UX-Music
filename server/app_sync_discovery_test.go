package server

import (
	"testing"
	"time"
)

func TestSyncDiscoveryTimeout_clampsUserInput(t *testing.T) {
	if got := syncDiscoveryTimeout(0); got != 2*time.Second {
		t.Fatalf("expected default timeout, got %s", got)
	}
	if got := syncDiscoveryTimeout(250); got != 250*time.Millisecond {
		t.Fatalf("expected 250ms timeout, got %s", got)
	}
	if got := syncDiscoveryTimeout(60000); got != 10*time.Second {
		t.Fatalf("expected max timeout, got %s", got)
	}
}

func TestMergeSyncKnownPeers_addsStoredPeersToDiscoveryResults(t *testing.T) {
	discovered := []uxsync.MDNSPeer{{
		DeviceID:    "dev_windows",
		DisplayName: "mainPC",
		Host:        "mainPC.local",
		Hosts:       []string{"mainPC.local"},
		Port:        8765,
	}}
	known := []uxsync.MDNSPeer{{
		DeviceID:    "dev_mac_mini",
		DisplayName: "YukinoMac-mini",
		Host:        "192.168.0.226",
		Hosts:       []string{"192.168.0.226"},
		Port:        8765,
	}}

	merged := mergeSyncKnownPeers(discovered, known)

	if len(merged) != 2 {
		t.Fatalf("expected discovered and known peers, got %#v", merged)
	}
	if merged[1].DeviceID != "dev_mac_mini" || merged[1].Host != "192.168.0.226" {
		t.Fatalf("expected known peer to be appended, got %#v", merged)
	}
}
