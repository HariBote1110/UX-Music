package server

import (
	"testing"

	"ux-music-sidecar/internal/uxsync"
)

func TestSyncMDNSAdvertiseInfo_usesHostIdentity(t *testing.T) {
	info := syncMDNSAdvertiseInfo("dev_123", "Mac mini")
	text := uxsync.BuildMDNSText(info)
	values := map[string]string{}
	for _, item := range text {
		key, value := splitSyncMDNSText(item)
		values[key] = value
	}

	if values["deviceId"] != "dev_123" {
		t.Fatalf("unexpected deviceId TXT: %#v", values)
	}
	if values["displayName"] != "Mac mini" {
		t.Fatalf("unexpected displayName TXT: %#v", values)
	}
	if values["protocolVersion"] != syncProtocolVersion {
		t.Fatalf("unexpected protocolVersion TXT: %#v", values)
	}
	if values["schemaVersion"] != syncSchemaVersion {
		t.Fatalf("unexpected schemaVersion TXT: %#v", values)
	}
	if !containsCSVToken(values["capabilities"], "library.import.v1") {
		t.Fatalf("capabilities TXT should include import support: %#v", values)
	}
	if values["roles"] != "LibraryHost,PlaybackTarget,Controller" {
		t.Fatalf("unexpected roles TXT: %#v", values)
	}
}

func TestSyncMDNSAdvertiseInfo_stripsLocalDomainFromDisplayName(t *testing.T) {
	info := syncMDNSAdvertiseInfo("dev_123", "YukinoMac-mini.local")
	if info.DisplayName != "YukinoMac-mini" {
		t.Fatalf("expected .local suffix to be stripped, got %q", info.DisplayName)
	}
}

func TestNormaliseSyncDisplayName(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "local suffix", raw: "YukinoMac-mini.local", want: "YukinoMac-mini"},
		{name: "plain name", raw: " mainPC ", want: "mainPC"},
		{name: "empty fallback", raw: "", want: "UX Music"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := normaliseSyncDisplayName(tt.raw); got != tt.want {
				t.Fatalf("normaliseSyncDisplayName(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}
