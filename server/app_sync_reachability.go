package server

import (
	"fmt"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

func resolveSyncDeviceForContact(device SyncDeviceRecord) (SyncDeviceRecord, error) {
	deviceID := strings.TrimSpace(device.DeviceID)
	baseURL := strings.TrimRight(strings.TrimSpace(device.BaseURL), "/")
	if deviceID == "" || baseURL == "" {
		return device, nil
	}

	known := syncKnownPeerRecord{
		DeviceID:    deviceID,
		DisplayName: device.DisplayName,
		BaseURL:     baseURL,
		Roles:       device.Roles,
		LastSeenAt:  device.LastSeenAt,
	}
	peer, ok := syncKnownPeerRecordToMDNSPeer(known)
	if !ok {
		return device, nil
	}
	resolved, err := uxsync.ResolveReachablePeer(peer, nil)
	if err != nil {
		// Some sync endpoints (for example a cached asset endpoint) can be
		// contacted successfully even when the peer does not expose identity.
		// Preserve the original URL and let that request report its own error.
		return device, nil
	}
	recoveredBaseURL := strings.TrimRight(strings.TrimSpace(resolved.ReachableBaseURL), "/")
	if recoveredBaseURL == "" {
		return device, fmt.Errorf("sync peer %s has no reachable base URL", deviceID)
	}
	device.BaseURL = recoveredBaseURL
	if recoveredBaseURL == baseURL {
		return device, nil
	}

	known.BaseURL = recoveredBaseURL
	known.LastSeenAt = time.Now().UTC().Format(time.RFC3339)
	if err := rememberSyncKnownPeer(known); err != nil {
		fmt.Printf("[Sync] Failed to persist reachable peer %s: %v\n", deviceID, err)
	}
	device.LastSeenAt = known.LastSeenAt
	return device, nil
}

func resolveSyncBaseURLForContact(baseURL string) (string, error) {
	normalised, err := normaliseSyncBaseURL(baseURL)
	if err != nil {
		return "", err
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return normalised, nil
	}
	for _, known := range decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey]) {
		knownBaseURL, err := normaliseSyncBaseURL(known.BaseURL)
		if err != nil || knownBaseURL != normalised {
			continue
		}
		device, err := resolveSyncDeviceForContact(SyncDeviceRecord{
			DeviceID:    known.DeviceID,
			DisplayName: known.DisplayName,
			BaseURL:     knownBaseURL,
			Roles:       known.Roles,
			Paired:      true,
			LastSeenAt:  known.LastSeenAt,
		})
		if err != nil {
			return "", err
		}
		return device.BaseURL, nil
	}
	return normalised, nil
}
