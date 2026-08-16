package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/uxsync"
)

const syncPairingTTL = 2 * time.Minute
const pairingRedeemSecretTTL = 5 * time.Minute

var syncPairingSessions = struct {
	mu       sync.Mutex
	sessions map[string]uxsync.PairingSession
}{
	sessions: map[string]uxsync.PairingSession{},
}

var syncPairingDetails = struct {
	mu       sync.Mutex
	sessions map[string]syncPairingSessionDetail
}{
	sessions: map[string]syncPairingSessionDetail{},
}

var pairingRedeemSecrets = struct {
	mu      sync.Mutex
	secrets map[string]time.Time
}{
	secrets: map[string]time.Time{},
}

type syncPairingSessionDetail struct {
	DeviceID    string
	DisplayName string
	BaseURL     string
}

type syncPairingStartRequest struct {
	DeviceID         string `json:"deviceId"`
	DisplayName      string `json:"displayName"`
	InitiatorBaseURL string `json:"initiatorBaseUrl,omitempty"`
}

type syncPairingStartResponse struct {
	SessionID string `json:"sessionId"`
	DeviceID  string `json:"deviceId"`
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

type syncPairingConfirmRequest struct {
	SessionID            string `json:"sessionId"`
	Code                 string `json:"code"`
	InitiatorDeviceID    string `json:"initiatorDeviceId,omitempty"`
	InitiatorDisplayName string `json:"initiatorDisplayName,omitempty"`
	InitiatorBaseURL     string `json:"initiatorBaseUrl,omitempty"`
}

type syncPairingConfirmResponse struct {
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

// pairingRedeemRequest is sent by mobile/companion clients that scanned the
// QR code produced by GetPairingURL / GetPairingQRDataURL. It presents the
// one-time secret embedded in the QR code together with a self-chosen device
// identity, and receives a device-specific auth token in exchange.
type pairingRedeemRequest struct {
	Secret      string `json:"secret"`
	DeviceID    string `json:"deviceId"`
	DisplayName string `json:"displayName,omitempty"`
}

type pairingRedeemResponse struct {
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

func registerPairingRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/v1/identity", identityHandler)
	mux.HandleFunc("/v1/pairing/start", syncPairingStartHandler)
	mux.HandleFunc("/v1/pairing/confirm", syncPairingConfirmHandler)
	mux.HandleFunc("/v1/pairing/redeem", pairingRedeemHandler)
}

func syncPairingStartHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req syncPairingStartRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		writeAPIError(w, "missing deviceId", http.StatusBadRequest)
		return
	}

	secret := randomBytes(32)
	sessionID := randomHex(16)
	session := uxsync.NewPairingSession(deviceID, secret, time.Now().UTC(), syncPairingTTL)

	syncPairingSessions.mu.Lock()
	syncPairingSessions.sessions[sessionID] = session
	syncPairingSessions.mu.Unlock()

	baseURL := syncRemoteBaseURL(r)
	if advertisedBaseURL, err := normaliseSyncBaseURL(req.InitiatorBaseURL); err == nil {
		baseURL = advertisedBaseURL
	}

	syncPairingDetails.mu.Lock()
	syncPairingDetails.sessions[sessionID] = syncPairingSessionDetail{
		DeviceID:    session.DeviceID,
		DisplayName: normaliseSyncDisplayName(req.DisplayName),
		BaseURL:     baseURL,
	}
	syncPairingDetails.mu.Unlock()

	writeJSON(w, syncPairingStartResponse{
		SessionID: sessionID,
		DeviceID:  session.DeviceID,
		Code:      session.Code,
		ExpiresAt: session.ExpiresAt.Format(time.RFC3339),
	})
}

func syncPairingConfirmHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req syncPairingConfirmRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	sessionID := strings.TrimSpace(req.SessionID)
	code := strings.TrimSpace(req.Code)

	var detail syncPairingSessionDetail
	syncPairingSessions.mu.Lock()
	session, ok := syncPairingSessions.sessions[sessionID]
	if ok && (session.IsExpired(time.Now().UTC()) || session.Code != code) {
		ok = false
	}
	if ok {
		delete(syncPairingSessions.sessions, sessionID)
	}
	syncPairingSessions.mu.Unlock()

	syncPairingDetails.mu.Lock()
	if ok {
		detail = syncPairingDetails.sessions[sessionID]
	}
	delete(syncPairingDetails.sessions, sessionID)
	syncPairingDetails.mu.Unlock()

	if !ok {
		writeAPIError(w, "invalid pairing code", http.StatusUnauthorized)
		return
	}

	token := ensureDeviceAuthToken(session.DeviceID)
	detail.DeviceID = session.DeviceID
	if displayName := normaliseSyncDisplayName(req.InitiatorDisplayName); strings.TrimSpace(req.InitiatorDisplayName) != "" {
		detail.DisplayName = displayName
	}
	if baseURL, err := normaliseSyncBaseURL(req.InitiatorBaseURL); err == nil {
		detail.BaseURL = baseURL
	}
	if detail.DisplayName == "" || detail.DisplayName == "UX Music" {
		detail.DisplayName = session.DeviceID
	}
	if detail.BaseURL != "" {
		_ = rememberSyncKnownPeer(syncKnownPeerRecord{
			DeviceID:    detail.DeviceID,
			DisplayName: detail.DisplayName,
			BaseURL:     detail.BaseURL,
			LastSeenAt:  time.Now().UTC().Format(time.RFC3339),
		})
	}
	writeJSON(w, syncPairingConfirmResponse{
		DeviceID: session.DeviceID,
		Token:    token,
	})
}

func pairingRedeemHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req pairingRedeemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	secret := strings.TrimSpace(req.Secret)
	deviceID := strings.TrimSpace(req.DeviceID)
	if secret == "" {
		writeAPIError(w, "missing secret", http.StatusBadRequest)
		return
	}
	if deviceID == "" {
		writeAPIError(w, "missing deviceId", http.StatusBadRequest)
		return
	}
	if !consumePairingRedeemSecret(secret) {
		writeAPIError(w, "invalid or expired secret", http.StatusUnauthorized)
		return
	}

	token := ensureDeviceAuthToken(deviceID)
	if err := saveRemoteDeviceName(deviceID, req.DisplayName); err != nil {
		fmt.Printf("[Pairing] Failed to save device display name: %v\n", err)
	}
	writeJSON(w, pairingRedeemResponse{
		DeviceID: deviceID,
		Token:    token,
	})
}

// newPairingRedeemSecret mints a fresh one-time secret for QR-code pairing
// and stores it with an expiry. Expired secrets are pruned opportunistically.
func newPairingRedeemSecret() string {
	pairingRedeemSecrets.mu.Lock()
	defer pairingRedeemSecrets.mu.Unlock()

	now := time.Now().UTC()
	for secret, expiresAt := range pairingRedeemSecrets.secrets {
		if now.After(expiresAt) {
			delete(pairingRedeemSecrets.secrets, secret)
		}
	}

	secret := randomHex(24)
	pairingRedeemSecrets.secrets[secret] = now.Add(pairingRedeemSecretTTL)
	return secret
}

// consumePairingRedeemSecret validates and invalidates a one-time secret,
// returning false if it is unknown, already used, or expired.
func consumePairingRedeemSecret(secret string) bool {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return false
	}
	pairingRedeemSecrets.mu.Lock()
	defer pairingRedeemSecrets.mu.Unlock()

	expiresAt, ok := pairingRedeemSecrets.secrets[secret]
	if !ok {
		return false
	}
	delete(pairingRedeemSecrets.secrets, secret)
	return time.Now().UTC().Before(expiresAt)
}
