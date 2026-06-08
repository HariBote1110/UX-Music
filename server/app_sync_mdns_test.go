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
	if values["protocolVersion"] != "0.1" {
		t.Fatalf("unexpected protocolVersion TXT: %#v", values)
	}
	if values["roles"] != "LibraryHost,PlaybackTarget,Controller" {
		t.Fatalf("unexpected roles TXT: %#v", values)
	}
}
