package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSyncPairingStartAndConfirmIssuesToken(t *testing.T) {
	newTempSyncStore(t)
	startReq := httptest.NewRequest(http.MethodPost, "/sync/pairing/start", bytes.NewReader([]byte(`{"deviceId":"macbook-air"}`)))
	startRec := httptest.NewRecorder()

	syncPairingStartHandler(startRec, startReq)

	if startRec.Code != http.StatusOK {
		t.Fatalf("unexpected start status %d: %s", startRec.Code, startRec.Body.String())
	}
	var started syncPairingStartResponse
	if err := json.Unmarshal(startRec.Body.Bytes(), &started); err != nil {
		t.Fatalf("decode start response: %v", err)
	}
	if len(started.Code) != 6 || started.SessionID == "" {
		t.Fatalf("unexpected pairing start response: %#v", started)
	}

	confirmPayload, _ := json.Marshal(map[string]string{
		"sessionId": started.SessionID,
		"code":      started.Code,
	})
	confirmReq := httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(confirmPayload))
	confirmRec := httptest.NewRecorder()

	syncPairingConfirmHandler(confirmRec, confirmReq)

	if confirmRec.Code != http.StatusOK {
		t.Fatalf("unexpected confirm status %d: %s", confirmRec.Code, confirmRec.Body.String())
	}
	var confirmed syncPairingConfirmResponse
	if err := json.Unmarshal(confirmRec.Body.Bytes(), &confirmed); err != nil {
		t.Fatalf("decode confirm response: %v", err)
	}
	if confirmed.Token == "" || confirmed.DeviceID != "macbook-air" {
		t.Fatalf("unexpected confirm response: %#v", confirmed)
	}
}

func TestSyncAuthMiddlewareRequiresTokenForLibraryEvents(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("macbook-air")
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	})
	handler := syncAuthMiddleware(next)

	missing := httptest.NewRecorder()
	handler.ServeHTTP(missing, httptest.NewRequest(http.MethodPost, "/sync/library/events", nil))
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorised without token, got %d", missing.Code)
	}

	withToken := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	handler.ServeHTTP(withToken, req)
	if withToken.Code != http.StatusAccepted {
		t.Fatalf("expected request with token to pass, got %d", withToken.Code)
	}
}

func TestLanAuthMiddlewareRoutesSyncAndWearAuthSeparately(t *testing.T) {
	newTempSyncStore(t)
	syncToken := ensureSyncAuthTokenForDevice("macbook-air")
	wearToken := ensureWearAuthToken()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	})
	handler := lanAuthMiddleware(next)

	syncReq := httptest.NewRequest(http.MethodPost, "/sync/library/events", nil)
	syncReq.Header.Set("X-UX-Music-Sync-Token", syncToken)
	syncRec := httptest.NewRecorder()
	handler.ServeHTTP(syncRec, syncReq)
	if syncRec.Code != http.StatusAccepted {
		t.Fatalf("expected sync token to pass sync route, got %d", syncRec.Code)
	}

	wearReq := httptest.NewRequest(http.MethodGet, "/wear/songs", nil)
	wearReq.Header.Set("X-UX-Music-Token", wearToken)
	wearRec := httptest.NewRecorder()
	handler.ServeHTTP(wearRec, wearReq)
	if wearRec.Code != http.StatusAccepted {
		t.Fatalf("expected wear token to pass wear route, got %d", wearRec.Code)
	}
}
