//go:build darwin

package uxsync

import "testing"

func TestParseDNSSDBrowseInstances_keepsInstanceName(t *testing.T) {
	output := `Browsing for _uxmusic-sync._tcp.local
DATE: ---Mon 08 Jun 2026---
17:29:08.461  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
17:29:08.590  Add        2  14 local.               _uxmusic-sync._tcp.  mainPC
`

	instances := parseDNSSDBrowseInstances(output)

	if len(instances) != 1 || instances[0] != "mainPC" {
		t.Fatalf("unexpected instances: %#v", instances)
	}
}

func TestParseDNSSDLookupOutput_readsSyncPeer(t *testing.T) {
	output := `Lookup mainPC._uxmusic-sync._tcp.local
DATE: ---Mon 08 Jun 2026---
17:29:31.049  ...STARTING...
17:29:31.049  mainPC._uxmusic-sync._tcp.local. can be reached at mainPC.local.:8765 (interface 14)
 deviceId=dev_0057 displayName=mainPC protocolVersion=0.1 roles=LibraryHost,PlaybackTarget,Controller
`

	peer, ok := parseDNSSDLookupOutput("mainPC", output)

	if !ok {
		t.Fatal("expected lookup output to parse")
	}
	if peer.DeviceID != "dev_0057" || peer.DisplayName != "mainPC" {
		t.Fatalf("unexpected identity: %#v", peer)
	}
	if peer.Host != "mainPC.local" || peer.Port != 8765 {
		t.Fatalf("unexpected endpoint: %#v", peer)
	}
	if len(peer.Roles) != 3 || peer.Roles[0] != "LibraryHost" || peer.Roles[2] != "Controller" {
		t.Fatalf("unexpected roles: %#v", peer.Roles)
	}
}
