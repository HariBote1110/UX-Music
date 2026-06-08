package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

const syncPlayEventsStoreName = "sync-play-events"
const syncAuthTokensSettingsKey = "syncAuthTokens"
const syncDeviceIDSettingsKey = "syncDeviceId"
const syncPairingTTL = 2 * time.Minute

var syncPairingSessions = struct {
	mu       sync.Mutex
	sessions map[string]uxsync.PairingSession
}{
	sessions: map[string]uxsync.PairingSession{},
}

type syncLibraryEventsRequest struct {
	DeviceID   string             `json:"deviceId"`
	PlayEvents []uxsync.PlayEvent `json:"playEvents"`
}

type syncLibraryEventsResponse struct {
	Accepted int             `json:"accepted"`
	Ack      uxsync.EventAck `json:"ack"`
}

type syncPairingStartRequest struct {
	DeviceID string `json:"deviceId"`
}

type syncPairingStartResponse struct {
	SessionID string `json:"sessionId"`
	DeviceID  string `json:"deviceId"`
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

type syncPairingConfirmRequest struct {
	SessionID string `json:"sessionId"`
	Code      string `json:"code"`
}

type syncPairingConfirmResponse struct {
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

type syncIdentityResponse struct {
	DeviceID        string   `json:"deviceId"`
	DisplayName     string   `json:"displayName"`
	Hostname        string   `json:"hostname"`
	ProtocolVersion string   `json:"protocolVersion"`
	Roles           []string `json:"roles"`
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

func registerSyncRoutes(mux *http.ServeMux, _ *App) {
	mux.HandleFunc("/sync/identity", syncIdentityHandler)
	mux.HandleFunc("/sync/pairing/start", syncPairingStartHandler)
	mux.HandleFunc("/sync/pairing/confirm", syncPairingConfirmHandler)
	mux.HandleFunc("/sync/library/events", syncLibraryEventsHandler)
	mux.HandleFunc("/sync/discover", syncDiscoverHandler)
}

func syncIdentityHandler(w http.ResponseWriter, r *http.Request) {
	hostname := "UX Music"
	if h, err := os.Hostname(); err == nil && strings.TrimSpace(h) != "" {
		hostname = strings.TrimSpace(h)
	}
	info := syncMDNSAdvertiseInfo(ensureSyncDeviceID(), hostname)
	writeJSON(w, map[string]interface{}{
		"role":            "ux-music-sync",
		"deviceId":        info.DeviceID,
		"hostname":        hostname,
		"displayName":     info.DisplayName,
		"protocolVersion": "0.1",
		"roles":           info.Roles,
	})
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
		http.Error(w, "failed to discover sync peers", http.StatusInternalServerError)
		return
	}
	writeJSON(w, uxsync.ResolveReachablePeers(peers, nil))
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
	return uxsync.ResolveReachablePeers(peers, nil), nil
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
	if err := postSyncJSON(ctx, baseURL+"/sync/pairing/start", syncPairingStartRequest{DeviceID: localDeviceID}, &started); err != nil {
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
	if err := postSyncJSON(ctx, baseURL+"/sync/pairing/confirm", syncPairingConfirmRequest{
		SessionID: strings.TrimSpace(sessionID),
		Code:      strings.TrimSpace(code),
	}, &confirmed); err != nil {
		return SyncPairingConfirmResult{}, err
	}
	if strings.TrimSpace(confirmed.Token) == "" {
		return SyncPairingConfirmResult{}, fmt.Errorf("pairing confirm response did not include a token")
	}
	if err := saveSyncAuthTokenForDevice(identity.DeviceID, confirmed.Token); err != nil {
		return SyncPairingConfirmResult{}, err
	}
	return SyncPairingConfirmResult{
		RemoteDeviceID:    identity.DeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
		TokenSaved:        true,
	}, nil
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
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/identity", nil)
	if err != nil {
		return syncIdentityResponse{}, err
	}
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
	if identity.DeviceID == "" {
		return syncIdentityResponse{}, fmt.Errorf("sync identity response did not include a device id")
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

func syncPairingStartHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req syncPairingStartRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		http.Error(w, "missing deviceId", http.StatusBadRequest)
		return
	}

	secret := randomBytes(32)
	sessionID := randomHex(16)
	session := uxsync.NewPairingSession(deviceID, secret, time.Now().UTC(), syncPairingTTL)

	syncPairingSessions.mu.Lock()
	syncPairingSessions.sessions[sessionID] = session
	syncPairingSessions.mu.Unlock()

	writeJSON(w, syncPairingStartResponse{
		SessionID: sessionID,
		DeviceID:  session.DeviceID,
		Code:      session.Code,
		ExpiresAt: session.ExpiresAt.Format(time.RFC3339),
	})
}

func syncPairingConfirmHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req syncPairingConfirmRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	sessionID := strings.TrimSpace(req.SessionID)
	code := strings.TrimSpace(req.Code)

	syncPairingSessions.mu.Lock()
	session, ok := syncPairingSessions.sessions[sessionID]
	if ok && (session.IsExpired(time.Now().UTC()) || session.Code != code) {
		ok = false
	}
	if ok {
		delete(syncPairingSessions.sessions, sessionID)
	}
	syncPairingSessions.mu.Unlock()

	if !ok {
		http.Error(w, "invalid pairing code", http.StatusUnauthorized)
		return
	}

	token := ensureSyncAuthTokenForDevice(session.DeviceID)
	writeJSON(w, syncPairingConfirmResponse{
		DeviceID: session.DeviceID,
		Token:    token,
	})
}

func syncLibraryEventsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req syncLibraryEventsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	req.DeviceID = strings.TrimSpace(req.DeviceID)
	normalisePlayEventDevices(req.DeviceID, req.PlayEvents)

	existing, err := loadSyncPlayEvents()
	if err != nil {
		http.Error(w, "failed to load sync play events", http.StatusInternalServerError)
		return
	}

	merged := uxsync.MergePlayEvents(existing, req.PlayEvents)
	if err := store.Instance.Save(syncPlayEventsStoreName, merged); err != nil {
		http.Error(w, "failed to save sync play events", http.StatusInternalServerError)
		return
	}

	writeJSON(w, syncLibraryEventsResponse{
		Accepted: len(req.PlayEvents),
		Ack: uxsync.EventAck{
			DeviceID:          req.DeviceID,
			MaxDeviceSequence: maxDeviceSequence(req.DeviceID, req.PlayEvents),
			AckedEventIDs:     eventIDs(req.PlayEvents),
		},
	})
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

func lanAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/sync/") {
			syncAuthMiddleware(next).ServeHTTP(w, r)
			return
		}
		wearAuthMiddleware(next).ServeHTTP(w, r)
	})
}

func syncAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isSyncPublicEndpoint(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		if !syncRequestHasValidToken(r) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isSyncPublicEndpoint(path string) bool {
	return path == "/sync/identity" || path == "/sync/pairing/start" || path == "/sync/pairing/confirm"
}

func syncRequestHasValidToken(r *http.Request) bool {
	token := strings.TrimSpace(r.Header.Get("X-UX-Music-Sync-Token"))
	if token == "" {
		token = strings.TrimSpace(r.URL.Query().Get("syncToken"))
	}
	if token == "" {
		if auth := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(strings.ToLower(auth), "bearer ") {
			token = strings.TrimSpace(auth[len("bearer "):])
		}
	}
	if token == "" {
		return false
	}

	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return false
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	for _, raw := range rawTokens {
		expected, ok := raw.(string)
		if !ok {
			continue
		}
		if len(token) == len(expected) && subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1 {
			return true
		}
	}
	return false
}

func ensureSyncAuthTokenForDevice(deviceID string) string {
	deviceID = strings.TrimSpace(deviceID)
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if rawTokens == nil {
		rawTokens = map[string]interface{}{}
	}
	if token, ok := rawTokens[deviceID].(string); ok && strings.TrimSpace(token) != "" {
		return strings.TrimSpace(token)
	}
	token := generateWearAuthToken()
	if err := saveSyncAuthTokenForDevice(deviceID, token); err != nil {
		return token
	}
	return token
}

func saveSyncAuthTokenForDevice(deviceID, token string) error {
	deviceID = strings.TrimSpace(deviceID)
	token = strings.TrimSpace(token)
	if deviceID == "" {
		return fmt.Errorf("missing sync device id")
	}
	if token == "" {
		return fmt.Errorf("missing sync auth token")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if rawTokens == nil {
		rawTokens = map[string]interface{}{}
	}
	rawTokens[deviceID] = token
	settings[syncAuthTokensSettingsKey] = rawTokens
	return store.Instance.Save("settings", settings)
}

func randomBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err == nil {
		return b
	}
	return []byte(time.Now().UTC().Format(time.RFC3339Nano))
}

func randomHex(size int) string {
	return hex.EncodeToString(randomBytes(size))
}

func (ws *WearServer) startSyncMDNS() {
	info := syncMDNSAdvertiseInfo(ensureSyncDeviceID(), syncDisplayName())
	advertisement, err := uxsync.AdvertiseMDNS(info, parseWearServerPort())
	if err != nil {
		fmt.Printf("[Sync] mDNS advertise failed: %v\n", err)
		return
	}
	ws.syncInfo = info
	ws.syncMDNS = advertisement
	fmt.Printf("[Sync] mDNS advertising %s on %s.%s:%s\n", info.DisplayName, uxsync.MDNSServiceType, uxsync.MDNSDomain, wearServerPort)
}

func syncMDNSAdvertiseInfo(deviceID, displayName string) uxsync.MDNSAdvertiseInfo {
	return uxsync.MDNSAdvertiseInfo{
		DeviceID:        strings.TrimSpace(deviceID),
		DisplayName:     strings.TrimSpace(displayName),
		ProtocolVersion: "0.1",
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
		return strings.TrimSpace(hostname)
	}
	return "UX Music"
}

func parseWearServerPort() int {
	port, err := strconv.Atoi(wearServerPort)
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
