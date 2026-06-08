package uxsync

import "testing"

func TestBuildMDNSText_includesSyncIdentity(t *testing.T) {
	text := BuildMDNSText(MDNSAdvertiseInfo{
		DeviceID:        "dev_mac_mini",
		DisplayName:     "Living Room Mac mini",
		ProtocolVersion: "0.1",
		Roles:           []string{"LibraryHost", "PlaybackTarget"},
	})
	values := mdnsTextMap(text)

	if values["deviceId"] != "dev_mac_mini" {
		t.Fatalf("deviceId missing from TXT: %#v", values)
	}
	if values["displayName"] != "Living Room Mac mini" {
		t.Fatalf("displayName missing from TXT: %#v", values)
	}
	if values["protocolVersion"] != "0.1" {
		t.Fatalf("protocolVersion missing from TXT: %#v", values)
	}
	if values["roles"] != "LibraryHost,PlaybackTarget" {
		t.Fatalf("roles missing from TXT: %#v", values)
	}
}

func TestNormaliseMDNSPeer_prefersIPv4AndParsesRoles(t *testing.T) {
	peer := NormaliseMDNSPeer(MDNSServiceEntry{
		Instance: "UX Music on Mac mini",
		HostName: "mac-mini.local.",
		Port:     8765,
		AddrIPv4: []string{"192.168.0.226"},
		AddrIPv6: []string{"fe80::1"},
		Text: []string{
			"deviceId=dev_mac_mini",
			"displayName=Living Room Mac mini",
			"protocolVersion=0.1",
			"roles=LibraryHost,PlaybackTarget",
		},
	})

	if peer.DeviceID != "dev_mac_mini" {
		t.Fatalf("unexpected device id: %#v", peer)
	}
	if peer.DisplayName != "Living Room Mac mini" {
		t.Fatalf("unexpected display name: %#v", peer)
	}
	if peer.Host != "192.168.0.226" || peer.Port != 8765 {
		t.Fatalf("unexpected endpoint: %#v", peer)
	}
	if len(peer.Roles) != 2 || peer.Roles[0] != "LibraryHost" || peer.Roles[1] != "PlaybackTarget" {
		t.Fatalf("unexpected roles: %#v", peer.Roles)
	}
}

func TestMDNSServiceConstants(t *testing.T) {
	if MDNSServiceType != "_uxmusic-sync._tcp" {
		t.Fatalf("unexpected service type: %q", MDNSServiceType)
	}
	if MDNSDomain != "local." {
		t.Fatalf("unexpected domain: %q", MDNSDomain)
	}
}

func mdnsTextMap(text []string) map[string]string {
	values := map[string]string{}
	for _, item := range text {
		key, value := splitMDNSText(item)
		values[key] = value
	}
	return values
}
