package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"ux-music-sidecar/internal/store"
)

// deviceIDContextKey is the typed context key under which deviceAuthMiddleware
// attaches the authenticated caller's deviceID, for handlers that need to
// know who is calling (e.g. the sidecar directive, last-seen tracking).
type deviceIDContextKey struct{}

// deviceIDFromContext returns the authenticated deviceID attached by
// deviceAuthMiddleware, or "" if the request context carries none (e.g.
// public endpoints that bypass authentication).
func deviceIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(deviceIDContextKey{}).(string)
	return id
}

// deviceAuthTokensSettingsKey stores a map[deviceID]token shared by every LAN
// API caller (mobile companions, Apple Watch, and desktop sync peers alike).
// It replaces the former wearAuthToken (single shared token) and
// syncAuthTokens (desktop-only) settings keys.
const deviceAuthTokensSettingsKey = "deviceAuthTokens"

type apiErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type apiErrorBody struct {
	Error apiErrorDetail `json:"error"`
}

// writeAPIError writes a `{"error":{"code":"...","message":"..."}}` JSON body.
// It mirrors the (w, message, status) argument order of http.Error so call
// sites across the LAN API can share one error format without bespoke codes.
func writeAPIError(w http.ResponseWriter, message string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(apiErrorBody{
		Error: apiErrorDetail{
			Code:    apiErrorCodeForStatus(status),
			Message: message,
		},
	})
}

// writeAPIErrorWithCode is writeAPIError with an explicit error code,
// for call sites whose failure mode is not adequately named by the HTTP
// status alone (e.g. "gui_required" for a 409 that means "no Wails runtime").
func writeAPIErrorWithCode(w http.ResponseWriter, code, message string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(apiErrorBody{
		Error: apiErrorDetail{
			Code:    code,
			Message: message,
		},
	})
}

func apiErrorCodeForStatus(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "bad_request"
	case http.StatusUnauthorized:
		return "unauthorized"
	case http.StatusForbidden:
		return "forbidden"
	case http.StatusNotFound:
		return "not_found"
	case http.StatusMethodNotAllowed:
		return "method_not_allowed"
	case http.StatusInsufficientStorage:
		return "insufficient_storage"
	case http.StatusInternalServerError:
		return "internal_error"
	default:
		return "error"
	}
}

// ─── Common device-token authentication ────────────────────────────────────
//
// Every LAN API request other than /v1/identity and /v1/pairing/* must carry
// `Authorization: Bearer <token>` where <token> matches one of the entries in
// deviceAuthTokens. As an exception, media GET endpoints that cannot set
// headers (e.g. <img src>, AVPlayer) may pass the token as `?token=`.

func deviceAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isPublicLANEndpoint(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		deviceID, ok := lanRequestDeviceID(r)
		if !ok {
			writeAPIError(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		recordRemoteDeviceLastSeen(deviceID)
		maybeUpdateRemoteDeviceNameFromHeader(r, deviceID)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceIDContextKey{}, deviceID)))
	})
}

func isPublicLANEndpoint(path string) bool {
	// /v1/local/shutdown is not authenticated by device token; it is gated
	// instead by loopback remote address + headless mode (see app_local.go).
	return path == "/v1/identity" || strings.HasPrefix(path, "/v1/pairing/") || path == localShutdownPath
}

// isMediaQueryTokenEndpoint reports whether the given path may accept a
// `?token=` query parameter in place of the Authorization header. This is
// limited to media GET endpoints that are loaded by clients unable to attach
// custom headers.
func isMediaQueryTokenEndpoint(path string) bool {
	return strings.HasPrefix(path, "/v1/remote/file") || strings.HasPrefix(path, "/v1/remote/artwork/")
}

// lanRequestDeviceID validates the request's device token and returns the
// matched deviceID, or ("", false) if the token is missing or invalid.
func lanRequestDeviceID(r *http.Request) (string, bool) {
	token := ""
	if auth := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		token = strings.TrimSpace(auth[len("bearer "):])
	}
	if token == "" && isMediaQueryTokenEndpoint(r.URL.Path) {
		token = strings.TrimSpace(r.URL.Query().Get("token"))
	}
	if token == "" {
		return "", false
	}
	return deviceTokenIsValid(token)
}

// lanRequestHasValidDeviceToken is a bool-only convenience wrapper around
// lanRequestDeviceID, kept for call sites that do not need the deviceID.
func lanRequestHasValidDeviceToken(r *http.Request) bool {
	_, ok := lanRequestDeviceID(r)
	return ok
}

// deviceTokenIsValid checks token against every entry in deviceAuthTokens,
// returning the matched deviceID alongside the bool for callers that need to
// know who authenticated (not just that someone did).
func deviceTokenIsValid(token string) (string, bool) {
	token = strings.TrimSpace(token)
	if token == "" {
		return "", false
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return "", false
	}
	rawTokens, _ := settings[deviceAuthTokensSettingsKey].(map[string]interface{})
	for deviceID, raw := range rawTokens {
		expected, ok := raw.(string)
		if !ok {
			continue
		}
		if len(token) == len(expected) && subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1 {
			return deviceID, true
		}
	}
	return "", false
}

// ensureDeviceAuthToken returns the existing token for deviceID, generating
// and persisting a new one if none exists yet.
func ensureDeviceAuthToken(deviceID string) string {
	deviceID = strings.TrimSpace(deviceID)
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	rawTokens, _ := settings[deviceAuthTokensSettingsKey].(map[string]interface{})
	if token, ok := rawTokens[deviceID].(string); ok && strings.TrimSpace(token) != "" {
		return strings.TrimSpace(token)
	}
	token := generateAuthToken()
	if err := saveDeviceAuthToken(deviceID, token); err != nil {
		fmt.Printf("[LAN] Failed to save device auth token: %v\n", err)
	}
	return token
}

func saveDeviceAuthToken(deviceID, token string) error {
	deviceID = strings.TrimSpace(deviceID)
	token = strings.TrimSpace(token)
	if deviceID == "" {
		return fmt.Errorf("missing device id")
	}
	if token == "" {
		return fmt.Errorf("missing device auth token")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	rawTokens, _ := settings[deviceAuthTokensSettingsKey].(map[string]interface{})
	if rawTokens == nil {
		rawTokens = map[string]interface{}{}
	}
	rawTokens[deviceID] = token
	settings[deviceAuthTokensSettingsKey] = rawTokens
	return store.Instance.Save("settings", settings)
}

func deviceAuthTokenDeviceIDs(raw interface{}) []string {
	rawTokens, _ := raw.(map[string]interface{})
	ids := make([]string, 0, len(rawTokens))
	for deviceID, token := range rawTokens {
		if strings.TrimSpace(deviceID) == "" {
			continue
		}
		if strings.TrimSpace(fmt.Sprint(token)) == "" {
			continue
		}
		ids = append(ids, strings.TrimSpace(deviceID))
	}
	return ids
}

func generateAuthToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err == nil {
		return hex.EncodeToString(b[:])
	}
	fallback := sha256.Sum256([]byte(fmt.Sprintf("%d", time.Now().UnixNano())))
	return hex.EncodeToString(fallback[:])
}

func randomBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("crypto/rand is unavailable: %v", err))
	}
	return b
}

func randomHex(size int) string {
	return hex.EncodeToString(randomBytes(size))
}
