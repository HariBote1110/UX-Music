package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

const syncPlayEventsStoreName = "sync-play-events"
const syncPlayCountBaseStoreName = "playcounts-base"
const syncPlayCountBaseMigrationStoreName = "playcounts-base-migration"
const syncRemoteCatalogStoreName = "sync-remote-catalog"
const syncDeviceIDSettingsKey = "syncDeviceId"
const syncKnownPeersSettingsKey = "syncKnownPeers"
const syncMinFreeSpaceGBSettingsKey = "syncMinFreeSpaceGB"
const syncCachePolicySettingsKey = "syncCachePolicy"
const syncPreferredFormatSettingsKey = "syncPreferredFormat"

type syncLibraryEventsRequest struct {
	DeviceID   string             `json:"deviceId"`
	PlayEvents []uxsync.PlayEvent `json:"playEvents"`
}

type syncLibraryEventsResponse struct {
	Accepted int             `json:"accepted"`
	Ack      uxsync.EventAck `json:"ack"`
}

type syncIdentityResponse struct {
	Role                         string                  `json:"role,omitempty"`
	DeviceID                     string                  `json:"deviceId"`
	DisplayName                  string                  `json:"displayName"`
	Hostname                     string                  `json:"hostname"`
	ProtocolVersion              string                  `json:"protocolVersion"`
	MinCompatibleProtocolVersion string                  `json:"minCompatibleProtocolVersion,omitempty"`
	SchemaVersion                string                  `json:"schemaVersion,omitempty"`
	Capabilities                 []string                `json:"capabilities,omitempty"`
	Roles                        []string                `json:"roles"`
	Negotiation                  syncProtocolNegotiation `json:"negotiation,omitempty"`
	Extensions                   map[string]interface{}  `json:"extensions,omitempty"`
}

type SyncPairingStartResult struct {
	BaseURL           string `json:"baseUrl"`
	SessionID         string `json:"sessionId"`
	LocalDeviceID     string `json:"localDeviceId"`
	RemoteDeviceID    string `json:"remoteDeviceId"`
	RemoteDisplayName string `json:"remoteDisplayName"`
	Code              string `json:"code"`
	ExpiresAt         string `json:"expiresAt"`
}

type SyncPairingConfirmResult struct {
	RemoteDeviceID    string `json:"remoteDeviceId"`
	RemoteDisplayName string `json:"remoteDisplayName"`
	TokenSaved        bool   `json:"tokenSaved"`
}

type SyncDeviceRecord struct {
	DeviceID    string   `json:"deviceId"`
	DisplayName string   `json:"displayName"`
	BaseURL     string   `json:"baseUrl,omitempty"`
	Roles       []string `json:"roles,omitempty"`
	Paired      bool     `json:"paired"`
	LastSeenAt  string   `json:"lastSeenAt,omitempty"`
}

type syncKnownPeerRecord struct {
	DeviceID    string   `json:"deviceId"`
	DisplayName string   `json:"displayName"`
	BaseURL     string   `json:"baseUrl"`
	Roles       []string `json:"roles,omitempty"`
	LastSeenAt  string   `json:"lastSeenAt"`
}

func registerSyncRoutes(mux *http.ServeMux, app *App) {
	mux.HandleFunc("/v1/sync/library/import", syncLibraryImportHandler)
	mux.HandleFunc("/v1/sync/library/snapshot", syncLibrarySnapshotHandler)
	mux.HandleFunc("/v1/sync/library/events", app.syncLibraryEventsHandler)
	mux.HandleFunc("/v1/sync/assets/", syncAssetFileHandler)
	mux.HandleFunc("/v1/sync/discover", syncDiscoverHandler)
}

func syncDiscoverHandler(w http.ResponseWriter, r *http.Request) {
	timeout := syncDiscoveryTimeout(0)
	if raw := strings.TrimSpace(r.URL.Query().Get("timeoutMs")); raw != "" {
		if ms, err := strconv.Atoi(raw); err == nil {
			timeout = syncDiscoveryTimeout(ms)
		}
	}
	peers, err := uxsync.DiscoverMDNS(r.Context(), timeout)
	if err != nil {
		writeAPIError(w, "failed to discover sync peers", http.StatusInternalServerError)
		return
	}
	writeJSON(w, uxsync.ResolveReachablePeers(mergeSyncKnownPeers(peers, loadSyncKnownPeers()), nil))
}

func (a *App) DiscoverSyncDevices(timeoutMs int) ([]uxsync.MDNSPeer, error) {
	ctx := context.Background()
	if a.ctx != nil {
		ctx = a.ctx
	}
	peers, err := uxsync.DiscoverMDNS(ctx, syncDiscoveryTimeout(timeoutMs))
	if err != nil {
		return nil, err
	}
	return uxsync.ResolveReachablePeers(mergeSyncKnownPeers(peers, loadSyncKnownPeers()), nil), nil
}

func (a *App) StartSyncPairing(baseURL string) (SyncPairingStartResult, error) {
	ctx := context.Background()
	if a.ctx != nil {
		ctx = a.ctx
	}
	baseURL, err := normaliseSyncBaseURL(baseURL)
	if err != nil {
		return SyncPairingStartResult{}, err
	}
	identity, err := fetchSyncIdentity(ctx, baseURL)
	if err != nil {
		return SyncPairingStartResult{}, err
	}
	localDeviceID := ensureSyncDeviceID()
	var started syncPairingStartResponse
	if err := postSyncJSON(ctx, baseURL+"/v1/pairing/start", syncPairingStartRequest{
		DeviceID:         localDeviceID,
		DisplayName:      syncDisplayName(),
		InitiatorBaseURL: syncLocalBaseURL(),
	}, &started); err != nil {
		return SyncPairingStartResult{}, err
	}
	if strings.TrimSpace(started.SessionID) == "" || strings.TrimSpace(started.Code) == "" {
		return SyncPairingStartResult{}, fmt.Errorf("invalid pairing start response")
	}
	return SyncPairingStartResult{
		BaseURL:           baseURL,
		SessionID:         strings.TrimSpace(started.SessionID),
		LocalDeviceID:     localDeviceID,
		RemoteDeviceID:    identity.DeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
		Code:              strings.TrimSpace(started.Code),
		ExpiresAt:         strings.TrimSpace(started.ExpiresAt),
	}, nil
}

func (a *App) ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID string) (SyncPairingConfirmResult, error) {
	ctx := context.Background()
	if a.ctx != nil {
		ctx = a.ctx
	}
	baseURL, err := normaliseSyncBaseURL(baseURL)
	if err != nil {
		return SyncPairingConfirmResult{}, err
	}
	identity, err := fetchSyncIdentity(ctx, baseURL)
	if err != nil {
		return SyncPairingConfirmResult{}, err
	}
	if expectedRemoteDeviceID = strings.TrimSpace(expectedRemoteDeviceID); expectedRemoteDeviceID != "" && identity.DeviceID != expectedRemoteDeviceID {
		return SyncPairingConfirmResult{}, fmt.Errorf("sync peer changed during pairing")
	}
	var confirmed syncPairingConfirmResponse
	localDeviceID := ensureSyncDeviceID()
	if err := postSyncJSON(ctx, baseURL+"/v1/pairing/confirm", syncPairingConfirmRequest{
		SessionID:            strings.TrimSpace(sessionID),
		Code:                 strings.TrimSpace(code),
		InitiatorDeviceID:    localDeviceID,
		InitiatorDisplayName: syncDisplayName(),
		InitiatorBaseURL:     syncLocalBaseURL(),
	}, &confirmed); err != nil {
		return SyncPairingConfirmResult{}, err
	}
	if strings.TrimSpace(confirmed.Token) == "" {
		return SyncPairingConfirmResult{}, fmt.Errorf("pairing confirm response did not include a token")
	}
	if err := saveDeviceAuthToken(identity.DeviceID, confirmed.Token); err != nil {
		return SyncPairingConfirmResult{}, err
	}
	_ = rememberSyncKnownPeer(syncKnownPeerRecord{
		DeviceID:    identity.DeviceID,
		DisplayName: syncIdentityDisplayName(identity),
		BaseURL:     baseURL,
		Roles:       identity.Roles,
		LastSeenAt:  time.Now().UTC().Format(time.RFC3339),
	})
	return SyncPairingConfirmResult{
		RemoteDeviceID:    identity.DeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
		TokenSaved:        true,
	}, nil
}

func (a *App) ListSyncDevices() ([]SyncDeviceRecord, error) {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return []SyncDeviceRecord{}, nil
	}

	recordsByID := map[string]SyncDeviceRecord{}
	for _, known := range decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey]) {
		deviceID := strings.TrimSpace(known.DeviceID)
		if deviceID == "" {
			continue
		}
		displayName := normaliseSyncDisplayName(known.DisplayName)
		if displayName == "" || displayName == "UX Music" {
			displayName = deviceID
		}
		recordsByID[deviceID] = SyncDeviceRecord{
			DeviceID:    deviceID,
			DisplayName: displayName,
			BaseURL:     strings.TrimRight(strings.TrimSpace(known.BaseURL), "/"),
			Roles:       known.Roles,
			Paired:      false,
			LastSeenAt:  strings.TrimSpace(known.LastSeenAt),
		}
	}

	for _, deviceID := range deviceAuthTokenDeviceIDs(settings[deviceAuthTokensSettingsKey]) {
		record := recordsByID[deviceID]
		record.DeviceID = deviceID
		if strings.TrimSpace(record.DisplayName) == "" {
			record.DisplayName = deviceID
		}
		record.Paired = true
		recordsByID[deviceID] = record
	}

	records := make([]SyncDeviceRecord, 0, len(recordsByID))
	for _, record := range recordsByID {
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].DisplayName == records[j].DisplayName {
			return records[i].DeviceID < records[j].DeviceID
		}
		return records[i].DisplayName < records[j].DisplayName
	})
	return records, nil
}

func syncDiscoveryTimeout(timeoutMs int) time.Duration {
	if timeoutMs <= 0 {
		return 2 * time.Second
	}
	if timeoutMs > 10000 {
		return 10 * time.Second
	}
	return time.Duration(timeoutMs) * time.Millisecond
}

func normaliseSyncBaseURL(raw string) (string, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return "", fmt.Errorf("missing sync peer URL")
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return "", fmt.Errorf("invalid sync peer URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("unsupported sync peer URL scheme")
	}
	parsed.Path = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return strings.TrimRight(parsed.String(), "/"), nil
}

func fetchSyncIdentity(ctx context.Context, baseURL string) (syncIdentityResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/v1/identity", nil)
	if err != nil {
		return syncIdentityResponse{}, err
	}
	req.Header.Set(syncProtocolVersionHeader, syncProtocolVersion)
	req.Header.Set(syncSchemaVersionHeader, syncSchemaVersion)
	req.Header.Set(syncCapabilitiesHeader, syncCapabilitiesCSV())
	resp, err := syncHTTPClient().Do(req)
	if err != nil {
		return syncIdentityResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return syncIdentityResponse{}, fmt.Errorf("sync identity request failed: %s", resp.Status)
	}
	var identity syncIdentityResponse
	if err := json.NewDecoder(resp.Body).Decode(&identity); err != nil {
		return syncIdentityResponse{}, err
	}
	identity.DeviceID = strings.TrimSpace(identity.DeviceID)
	identity.DisplayName = strings.TrimSpace(identity.DisplayName)
	identity.Hostname = strings.TrimSpace(identity.Hostname)
	identity.ProtocolVersion = strings.TrimSpace(identity.ProtocolVersion)
	if identity.DeviceID == "" {
		return syncIdentityResponse{}, fmt.Errorf("sync identity response did not include a device id")
	}
	if !syncProtocolVersionsCompatible(identity.ProtocolVersion, syncProtocolVersion) {
		return syncIdentityResponse{}, fmt.Errorf("sync peer protocol is not compatible: remote=%s local=%s", identity.ProtocolVersion, syncProtocolVersion)
	}
	return identity, nil
}

func postSyncJSON(ctx context.Context, endpoint string, payload interface{}, target interface{}) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := syncHTTPClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("sync request failed: %s", resp.Status)
	}
	if target == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(target)
}

func syncHTTPClient() *http.Client {
	return &http.Client{Timeout: 5 * time.Second}
}

func syncIdentityDisplayName(identity syncIdentityResponse) string {
	if identity.DisplayName != "" {
		return identity.DisplayName
	}
	if identity.Hostname != "" {
		return identity.Hostname
	}
	return identity.DeviceID
}

func mergeSyncKnownPeers(discovered, known []uxsync.MDNSPeer) []uxsync.MDNSPeer {
	return uxsyncMergePeersWithoutProbe(discovered, known)
}

func uxsyncMergePeersWithoutProbe(primary, fallback []uxsync.MDNSPeer) []uxsync.MDNSPeer {
	merged := make([]uxsync.MDNSPeer, 0, len(primary)+len(fallback))
	indexByKey := map[string]int{}
	for _, peer := range append(primary, fallback...) {
		key := syncPeerMergeKey(peer)
		if existingIndex, ok := indexByKey[key]; ok {
			merged[existingIndex] = uxsync.MergeMDNSPeers(merged[existingIndex], peer)
			continue
		}
		indexByKey[key] = len(merged)
		merged = append(merged, peer)
	}
	return merged
}

func syncPeerMergeKey(peer uxsync.MDNSPeer) string {
	if strings.TrimSpace(peer.DeviceID) != "" {
		return "device:" + strings.TrimSpace(peer.DeviceID)
	}
	return "host:" + strings.TrimSpace(peer.Host) + ":" + strings.TrimSpace(peer.HostName)
}

func rememberSyncKnownPeer(peer syncKnownPeerRecord) error {
	peer.DeviceID = strings.TrimSpace(peer.DeviceID)
	peer.DisplayName = normaliseSyncDisplayName(peer.DisplayName)
	peer.BaseURL = strings.TrimRight(strings.TrimSpace(peer.BaseURL), "/")
	if peer.DeviceID == "" || peer.BaseURL == "" {
		return nil
	}
	if peer.LastSeenAt == "" {
		peer.LastSeenAt = time.Now().UTC().Format(time.RFC3339)
	}

	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	records := decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey])
	updated := false
	for i := range records {
		if records[i].DeviceID == peer.DeviceID {
			records[i] = peer
			updated = true
			break
		}
	}
	if !updated {
		records = append(records, peer)
	}
	settings[syncKnownPeersSettingsKey] = records
	return store.Instance.Save("settings", settings)
}

func loadSyncKnownPeers() []uxsync.MDNSPeer {
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return nil
	}
	records := decodeSyncKnownPeerRecords(settings[syncKnownPeersSettingsKey])
	peers := make([]uxsync.MDNSPeer, 0, len(records))
	for _, record := range records {
		peer, ok := syncKnownPeerRecordToMDNSPeer(record)
		if ok {
			peers = append(peers, peer)
		}
	}
	return peers
}

func decodeSyncKnownPeerRecords(raw interface{}) []syncKnownPeerRecord {
	if raw == nil {
		return nil
	}
	bytes, err := json.Marshal(raw)
	if err != nil {
		return nil
	}
	var records []syncKnownPeerRecord
	if err := json.Unmarshal(bytes, &records); err != nil {
		return nil
	}
	return records
}

func syncKnownPeerRecordToMDNSPeer(record syncKnownPeerRecord) (uxsync.MDNSPeer, bool) {
	baseURL := strings.TrimRight(strings.TrimSpace(record.BaseURL), "/")
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Hostname() == "" {
		return uxsync.MDNSPeer{}, false
	}
	port := parseLANServerPort()
	if parsed.Port() != "" {
		if parsedPort, err := strconv.Atoi(parsed.Port()); err == nil {
			port = parsedPort
		}
	}
	host := parsed.Hostname()
	return uxsync.MDNSPeer{
		DeviceID:        strings.TrimSpace(record.DeviceID),
		DisplayName:     normaliseSyncDisplayName(record.DisplayName),
		Host:            host,
		Hosts:           []string{host},
		Port:            port,
		HostName:        host,
		ProtocolVersion: syncProtocolVersion,
		SchemaVersion:   syncSchemaVersion,
		Capabilities:    syncCapabilities(),
		Roles:           record.Roles,
	}, true
}

func syncRemoteBaseURL(r *http.Request) string {
	if r == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err != nil {
		host = strings.TrimSpace(r.RemoteAddr)
	}
	if host == "" {
		return ""
	}
	return "http://" + net.JoinHostPort(host, lanServerPort)
}

func syncLocalBaseURL() string {
	address := strings.TrimSpace(GetLANServerAddress())
	if address == "" {
		address = "localhost:" + lanServerPort
	}
	return "http://" + address
}

func (a *App) syncLibraryEventsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req syncLibraryEventsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	req.DeviceID = strings.TrimSpace(req.DeviceID)
	normalisePlayEventDevices(req.DeviceID, req.PlayEvents)

	existing, err := loadSyncPlayEvents()
	if err != nil {
		writeAPIError(w, "failed to load sync play events", http.StatusInternalServerError)
		return
	}

	merged := uxsync.MergePlayEvents(existing, req.PlayEvents)
	if err := store.Instance.Save(syncPlayEventsStoreName, merged); err != nil {
		writeAPIError(w, "failed to save sync play events", http.StatusInternalServerError)
		return
	}
	if err := applyIncomingSyncPlayEventsToPlayCounts(syncNewPlayEvents(existing, req.PlayEvents)); err != nil {
		writeAPIError(w, "failed to apply sync play counts", http.StatusInternalServerError)
		return
	}
	a.emitPlayCountsUpdated()

	writeJSON(w, syncLibraryEventsResponse{
		Accepted: len(req.PlayEvents),
		Ack: uxsync.EventAck{
			DeviceID:          req.DeviceID,
			MaxDeviceSequence: maxDeviceSequence(req.DeviceID, req.PlayEvents),
			AckedEventIDs:     eventIDs(req.PlayEvents),
		},
	})
}

func (a *App) emitPlayCountsUpdated() {
	if a == nil || a.ctx == nil {
		return
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		return
	}
	a.emit("play-counts-updated", counts)
}

func loadSyncPlayEvents() ([]uxsync.PlayEvent, error) {
	raw, err := store.Instance.Load(syncPlayEventsStoreName)
	if err != nil || raw == nil {
		return []uxsync.PlayEvent{}, err
	}
	bytes, err := json.Marshal(raw)
	if err != nil {
		return nil, err
	}
	var events []uxsync.PlayEvent
	if err := json.Unmarshal(bytes, &events); err != nil {
		return nil, err
	}
	return events, nil
}

func normalisePlayEventDevices(deviceID string, events []uxsync.PlayEvent) {
	if deviceID == "" {
		return
	}
	for i := range events {
		if strings.TrimSpace(events[i].DeviceID) == "" {
			events[i].DeviceID = deviceID
		}
	}
}

func maxDeviceSequence(deviceID string, events []uxsync.PlayEvent) int64 {
	var max int64
	for _, event := range events {
		if deviceID != "" && event.DeviceID != deviceID {
			continue
		}
		if event.DeviceSequence > max {
			max = event.DeviceSequence
		}
	}
	return max
}

func eventIDs(events []uxsync.PlayEvent) []string {
	ids := make([]string, 0, len(events))
	for _, event := range events {
		id := strings.TrimSpace(event.EventID)
		if id != "" {
			ids = append(ids, id)
		}
	}
	return ids
}

func (ws *LANServer) startSyncMDNS() {
	info := syncMDNSAdvertiseInfo(ensureSyncDeviceID(), syncDisplayName())
	advertisement, err := uxsync.AdvertiseMDNS(info, parseLANServerPort())
	if err != nil {
		fmt.Printf("[Sync] mDNS advertise failed: %v\n", err)
		return
	}
	ws.syncInfo = info
	ws.syncMDNS = advertisement
	fmt.Printf("[Sync] mDNS advertising %s on %s.%s:%s\n", info.DisplayName, uxsync.MDNSServiceType, uxsync.MDNSDomain, lanServerPort)
}

func syncMDNSAdvertiseInfo(deviceID, displayName string) uxsync.MDNSAdvertiseInfo {
	return uxsync.MDNSAdvertiseInfo{
		DeviceID:        strings.TrimSpace(deviceID),
		DisplayName:     normaliseSyncDisplayName(displayName),
		ProtocolVersion: syncProtocolVersion,
		SchemaVersion:   syncSchemaVersion,
		Capabilities:    syncCapabilities(),
		Roles:           []string{"LibraryHost", "PlaybackTarget", "Controller"},
	}
}

func ensureSyncDeviceID() string {
	settings, err := store.Instance.LoadMap("settings")
	if err == nil {
		if deviceID, ok := settings[syncDeviceIDSettingsKey].(string); ok && strings.TrimSpace(deviceID) != "" {
			return strings.TrimSpace(deviceID)
		}
	}
	if settings == nil {
		settings = map[string]interface{}{}
	}
	deviceID := "dev_" + randomHex(16)
	settings[syncDeviceIDSettingsKey] = deviceID
	if err := store.Instance.Save("settings", settings); err != nil {
		fmt.Printf("[Sync] Failed to save device id: %v\n", err)
	}
	return deviceID
}

func syncDisplayName() string {
	if hostname, err := os.Hostname(); err == nil && strings.TrimSpace(hostname) != "" {
		return normaliseSyncDisplayName(hostname)
	}
	return "UX Music"
}

func normaliseSyncDisplayName(raw string) string {
	name := strings.TrimSpace(raw)
	name = strings.TrimSuffix(name, ".")
	if strings.HasSuffix(strings.ToLower(name), ".local") {
		name = strings.TrimSuffix(name[:len(name)-len(".local")], ".")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return "UX Music"
	}
	return name
}

func parseLANServerPort() int {
	port, err := strconv.Atoi(lanServerPort)
	if err != nil {
		return 8765
	}
	return port
}

func splitSyncMDNSText(item string) (string, string) {
	key, value, ok := strings.Cut(item, "=")
	if !ok {
		return strings.TrimSpace(item), ""
	}
	return strings.TrimSpace(key), strings.TrimSpace(value)
}
