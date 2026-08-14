package server

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/store"
)

// remoteDeviceNamesSettingsKey stores a map[deviceID]displayName, populated
// when a pairing flow supplies a human-readable device name (see
// pairingRedeemHandler in app_pairing.go). Devices with no recorded name are
// shown by deviceID alone.
const remoteDeviceNamesSettingsKey = "remoteDeviceNames"

// remoteDeviceOnlineWindow is how recently a device must have authenticated
// against the LAN API to be reported Online by ListPairedRemoteDevices.
const remoteDeviceOnlineWindow = 10 * time.Second

// remoteDeviceLastSeen tracks, in memory only, the last time each deviceID
// successfully authenticated against the LAN API (see deviceAuthMiddleware).
// It is intentionally not persisted: liveness is only meaningful for the
// current process's uptime.
var remoteDeviceLastSeen = struct {
	mu   sync.Mutex
	seen map[string]time.Time
}{seen: map[string]time.Time{}}

// recordRemoteDeviceLastSeen records that deviceID has just authenticated
// successfully. Called from deviceAuthMiddleware on every authenticated
// request.
func recordRemoteDeviceLastSeen(deviceID string) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return
	}
	remoteDeviceLastSeen.mu.Lock()
	remoteDeviceLastSeen.seen[deviceID] = time.Now().UTC()
	remoteDeviceLastSeen.mu.Unlock()
}

// remoteDeviceLastSeenAt returns the last-seen time for deviceID and whether
// one has been recorded at all in this process.
func remoteDeviceLastSeenAt(deviceID string) (time.Time, bool) {
	remoteDeviceLastSeen.mu.Lock()
	defer remoteDeviceLastSeen.mu.Unlock()
	t, ok := remoteDeviceLastSeen.seen[deviceID]
	return t, ok
}

// ─── Sidecar target ─────────────────────────────────────────────────────────
//
// The desktop can push a fullscreen "sidecar" now-playing display to one
// paired iOS device at a time. App.sidecarTargetDeviceID names that device
// (empty = no sidecar target). GET /v1/remote/state includes a "sidecar"
// directive telling each caller whether it is the current target. State
// lives on *App (rather than a package global) so each App instance —
// notably each test's NewApp() — starts with a clean slate.

// remoteDeviceNameFor returns the persisted display name for deviceID, or ""
// if none was recorded at pairing time.
func remoteDeviceNameFor(deviceID string) string {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return ""
	}
	rawNames, _ := settings[remoteDeviceNamesSettingsKey].(map[string]interface{})
	if rawNames == nil {
		return ""
	}
	name, _ := rawNames[deviceID].(string)
	return strings.TrimSpace(name)
}

// saveRemoteDeviceName persists a display name for deviceID, used by
// ListPairedRemoteDevices. Called from pairingRedeemHandler when the mobile
// pairing flow supplies one, and from deviceAuthMiddleware when a client
// self-reports its name via the X-Device-Name header.
func saveRemoteDeviceName(deviceID, displayName string) error {
	deviceID = strings.TrimSpace(deviceID)
	displayName = strings.TrimSpace(displayName)
	if deviceID == "" || displayName == "" {
		return nil
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	rawNames, _ := settings[remoteDeviceNamesSettingsKey].(map[string]interface{})
	if rawNames == nil {
		rawNames = map[string]interface{}{}
	}
	rawNames[deviceID] = displayName
	settings[remoteDeviceNamesSettingsKey] = rawNames
	return store.Instance.Save("settings", settings)
}

// remoteDeviceNameHeaderMaxLength caps the length of a self-reported
// X-Device-Name value before persisting it, defensively bounding what an
// LAN caller can write into settings.
const remoteDeviceNameHeaderMaxLength = 64

// maybeUpdateRemoteDeviceNameFromHeader reads the optional X-Device-Name
// header from r and, if it is non-empty and differs from the name already
// stored for deviceID, persists it via saveRemoteDeviceName. This lets
// clients self-report a display name on every authenticated LAN request,
// covering devices paired before remoteDeviceNames existed (whose name was
// otherwise only ever set at pairing-redeem time). A settings write is
// skipped when the (trimmed, truncated) name already matches, so routine
// polling does not hit the store on every request.
func maybeUpdateRemoteDeviceNameFromHeader(r *http.Request, deviceID string) {
	name := strings.TrimSpace(r.Header.Get("X-Device-Name"))
	if name == "" {
		return
	}
	if len(name) > remoteDeviceNameHeaderMaxLength {
		name = strings.TrimSpace(name[:remoteDeviceNameHeaderMaxLength])
	}
	if name == "" || name == remoteDeviceNameFor(deviceID) {
		return
	}
	if err := saveRemoteDeviceName(deviceID, name); err != nil {
		fmt.Printf("[LAN] Failed to save self-reported device name: %v\n", err)
	}
}

// PairedRemoteDevice is one entry returned by ListPairedRemoteDevices.
type PairedRemoteDevice struct {
	DeviceID    string `json:"deviceId"`
	DisplayName string `json:"displayName"`
	LastSeenAt  string `json:"lastSeenAt"`
	Online      bool   `json:"online"`
}

// ListPairedRemoteDevices returns every device holding a valid LAN API
// token, together with its display name (if one was recorded at pairing
// time), last-seen timestamp, and online status. Wails-bound for the sidecar
// target picker UI.
func (a *App) ListPairedRemoteDevices() []PairedRemoteDevice {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return []PairedRemoteDevice{}
	}
	deviceIDs := deviceAuthTokenDeviceIDs(settings[deviceAuthTokensSettingsKey])
	now := time.Now().UTC()
	devices := make([]PairedRemoteDevice, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		record := PairedRemoteDevice{
			DeviceID:    deviceID,
			DisplayName: remoteDeviceNameFor(deviceID),
		}
		if lastSeen, ok := remoteDeviceLastSeenAt(deviceID); ok {
			record.LastSeenAt = lastSeen.Format(time.RFC3339)
			record.Online = now.Sub(lastSeen) <= remoteDeviceOnlineWindow
		}
		devices = append(devices, record)
	}
	return devices
}

// SetSidecarTargetDevice sets the device that receives the sidecar
// directive in GET /v1/remote/state. An empty deviceID clears the target.
// Returns an error if deviceID is non-empty but not a paired device.
func (a *App) SetSidecarTargetDevice(deviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		a.sidecarMu.Lock()
		a.sidecarTargetDeviceID = ""
		a.sidecarMu.Unlock()
		return nil
	}
	if !deviceIDIsPaired(deviceID) {
		return fmt.Errorf("device %q is not paired", deviceID)
	}
	a.sidecarMu.Lock()
	a.sidecarTargetDeviceID = deviceID
	a.sidecarMu.Unlock()
	return nil
}

// GetSidecarTargetDevice returns the current sidecar target deviceID, or ""
// if none is set.
func (a *App) GetSidecarTargetDevice() string {
	a.sidecarMu.Lock()
	defer a.sidecarMu.Unlock()
	return a.sidecarTargetDeviceID
}

// deviceIDIsPaired reports whether deviceID currently holds a valid LAN API
// token (i.e. has not been unpaired/removed from deviceAuthTokens).
func deviceIDIsPaired(deviceID string) bool {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return false
	}
	for _, id := range deviceAuthTokenDeviceIDs(settings[deviceAuthTokensSettingsKey]) {
		if id == deviceID {
			return true
		}
	}
	return false
}

// sidecarDirectiveFor builds the "sidecar" block of GET /v1/remote/state for
// the given authenticated caller deviceID (may be "" for unauthenticated —
// active is always false in that case).
func (a *App) sidecarDirectiveFor(deviceID string) map[string]interface{} {
	a.sidecarMu.Lock()
	target := a.sidecarTargetDeviceID
	a.sidecarMu.Unlock()

	active := false
	if deviceID != "" && target != "" {
		if !deviceIDIsPaired(target) {
			// The target device was unpaired since being set; treat as
			// cleared rather than leaving a stale, un-actionable target.
			a.sidecarMu.Lock()
			if a.sidecarTargetDeviceID == target {
				a.sidecarTargetDeviceID = ""
			}
			a.sidecarMu.Unlock()
		} else {
			active = deviceID == target
		}
	}
	return map[string]interface{}{"active": active}
}
