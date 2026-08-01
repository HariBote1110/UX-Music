package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
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

func TestSyncPairingConfirmStoresKnownPeerFromInboundRequest(t *testing.T) {
	newTempSyncStore(t)
	startReq := httptest.NewRequest(http.MethodPost, "/sync/pairing/start", bytes.NewReader([]byte(`{
		"deviceId":"dev_mac_mini",
		"displayName":"YukinoMac-mini"
	}`)))
	startReq.RemoteAddr = "192.168.0.226:54321"
	startRec := httptest.NewRecorder()

	syncPairingStartHandler(startRec, startReq)

	if startRec.Code != http.StatusOK {
		t.Fatalf("unexpected start status %d: %s", startRec.Code, startRec.Body.String())
	}
	var started syncPairingStartResponse
	if err := json.Unmarshal(startRec.Body.Bytes(), &started); err != nil {
		t.Fatalf("decode start response: %v", err)
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
	peers := loadSyncKnownPeers()
	if len(peers) != 1 {
		t.Fatalf("expected one known peer, got %#v", peers)
	}
	peer := peers[0]
	if peer.DeviceID != "dev_mac_mini" || peer.DisplayName != "YukinoMac-mini" {
		t.Fatalf("unexpected known peer identity: %#v", peer)
	}
	if peer.Host != "192.168.0.226" || peer.Port != 8765 {
		t.Fatalf("expected known peer URL from remote address, got %#v", peer)
	}
}

func TestSyncPairingConfirmStoresInitiatorKnownPeerFromPayload(t *testing.T) {
	newTempSyncStore(t)
	startReq := httptest.NewRequest(http.MethodPost, "/sync/pairing/start", bytes.NewReader([]byte(`{
		"deviceId":"dev_air",
		"displayName":"MacBook Air",
		"initiatorBaseUrl":"http://192.168.0.143:8765"
	}`)))
	startRec := httptest.NewRecorder()

	syncPairingStartHandler(startRec, startReq)

	if startRec.Code != http.StatusOK {
		t.Fatalf("unexpected start status %d: %s", startRec.Code, startRec.Body.String())
	}
	var started syncPairingStartResponse
	if err := json.Unmarshal(startRec.Body.Bytes(), &started); err != nil {
		t.Fatalf("decode start response: %v", err)
	}

	confirmPayload, _ := json.Marshal(syncPairingConfirmRequest{
		SessionID:        started.SessionID,
		Code:             started.Code,
		InitiatorBaseURL: "http://192.168.0.144:8765",
	})
	confirmReq := httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(confirmPayload))
	confirmRec := httptest.NewRecorder()

	syncPairingConfirmHandler(confirmRec, confirmReq)

	if confirmRec.Code != http.StatusOK {
		t.Fatalf("unexpected confirm status %d: %s", confirmRec.Code, confirmRec.Body.String())
	}
	peers := loadSyncKnownPeers()
	if len(peers) != 1 {
		t.Fatalf("expected one known peer, got %#v", peers)
	}
	peer := peers[0]
	if peer.DeviceID != "dev_air" || peer.DisplayName != "MacBook Air" || peer.Host != "192.168.0.144" || peer.Port != 8765 {
		t.Fatalf("expected initiator known peer from confirm payload, got %#v", peer)
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

// corruptSyncToken は文字数を保ったまま末尾 1 文字だけ差し替えた別トークンを返す。
// syncRequestHasValidToken は長さが違うと ConstantTimeCompare まで到達しないため、
// 拒否経路を実際に踏ませるには同じ長さの誤りトークンが必要。
func corruptSyncToken(token string) string {
	if token == "" {
		return "x"
	}
	replacement := byte('a')
	if token[len(token)-1] == 'a' {
		replacement = 'b'
	}
	return token[:len(token)-1] + string(replacement)
}

func TestSyncAuthMiddlewareRejectsWrongToken(t *testing.T) {
	newTempSyncStore(t)
	valid := ensureSyncAuthTokenForDevice("macbook-air")
	wrong := corruptSyncToken(valid)
	if len(wrong) != len(valid) || wrong == valid {
		t.Fatalf("test setup: wrong token must be same length and different: valid=%q wrong=%q", valid, wrong)
	}
	nextCalled := false
	handler := syncAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusAccepted)
	}))

	cases := []struct {
		name    string
		prepare func(*http.Request)
	}{
		{name: "header", prepare: func(r *http.Request) { r.Header.Set("X-UX-Music-Sync-Token", wrong) }},
		{name: "query", prepare: func(r *http.Request) { r.URL.RawQuery = "syncToken=" + url.QueryEscape(wrong) }},
		{name: "bearer", prepare: func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+wrong) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nextCalled = false
			req := httptest.NewRequest(http.MethodPost, "/sync/library/events", nil)
			tc.prepare(req)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("expected 401 for wrong sync token, got %d", rec.Code)
			}
			if nextCalled {
				t.Fatal("wrong sync token reached the protected handler")
			}
		})
	}
}

func TestSyncAuthMiddlewareRejectsTokenOfUnpairedDevice(t *testing.T) {
	newTempSyncStore(t)
	// dev_paired だけをペアリング済みにし、別デバイス用に発行された形式的に正しい
	// トークンを提示する。ストアの tokens マップに載っていないので拒否されるはず。
	paired := ensureSyncAuthTokenForDevice("dev_paired")
	unpaired := generateWearAuthToken()
	if unpaired == paired {
		t.Fatalf("test setup: unpaired token collided with the paired one")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	tokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if _, exists := tokens["dev_unpaired"]; exists {
		t.Fatalf("test setup: dev_unpaired must not be stored, got %#v", tokens)
	}

	nextCalled := false
	handler := syncAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusAccepted)
	}))
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", nil)
	req.Header.Set("X-UX-Music-Sync-Token", unpaired)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unpaired device token, got %d", rec.Code)
	}
	if nextCalled {
		t.Fatal("unpaired device token reached the protected handler")
	}
}

// seedSyncPairingSession はペアリングセッションを直接ストアへ投入する。
// 期限切れケースを sleep せず決定的に再現するために使う。
func seedSyncPairingSession(t *testing.T, sessionID string, session uxsync.PairingSession) {
	t.Helper()
	syncPairingSessions.mu.Lock()
	syncPairingSessions.sessions[sessionID] = session
	syncPairingSessions.mu.Unlock()
	syncPairingDetails.mu.Lock()
	syncPairingDetails.sessions[sessionID] = syncPairingSessionDetail{
		DeviceID:    session.DeviceID,
		DisplayName: "MacBook Air",
		BaseURL:     "http://192.168.0.143:8765",
	}
	syncPairingDetails.mu.Unlock()
	t.Cleanup(func() {
		syncPairingSessions.mu.Lock()
		delete(syncPairingSessions.sessions, sessionID)
		syncPairingSessions.mu.Unlock()
		syncPairingDetails.mu.Lock()
		delete(syncPairingDetails.sessions, sessionID)
		syncPairingDetails.mu.Unlock()
	})
}

// requireNoSyncAuthTokenPersisted は settings にトークンが 1 件も書かれていない
// ことを確認する。401 を返しつつ裏でトークンを発行してしまう退行を検出する。
func requireNoSyncAuthTokenPersisted(t *testing.T) {
	t.Helper()
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	tokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	if len(tokens) != 0 {
		t.Fatalf("rejected pairing must not persist any auth token, got %#v", tokens)
	}
	if len(loadSyncKnownPeers()) != 0 {
		t.Fatalf("rejected pairing must not remember a peer, got %#v", loadSyncKnownPeers())
	}
}

func TestSyncPairingConfirmRejectsInvalidRequests(t *testing.T) {
	t.Run("expired session", func(t *testing.T) {
		newTempSyncStore(t)
		// 過去に期限が切れたセッションを直接投入する（sleep しない）。
		expired := uxsync.NewPairingSession("dev_air", []byte("shared pairing secret"), time.Now().UTC().Add(-10*time.Minute), time.Minute)
		seedSyncPairingSession(t, "session_expired", expired)

		payload, _ := json.Marshal(map[string]string{"sessionId": "session_expired", "code": expired.Code})
		rec := httptest.NewRecorder()
		syncPairingConfirmHandler(rec, httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(payload)))

		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for expired pairing session, got %d: %s", rec.Code, rec.Body.String())
		}
		requireNoSyncAuthTokenPersisted(t)
	})

	t.Run("wrong code", func(t *testing.T) {
		newTempSyncStore(t)
		session := uxsync.NewPairingSession("dev_air", []byte("shared pairing secret"), time.Now().UTC(), syncPairingTTL)
		seedSyncPairingSession(t, "session_wrong_code", session)
		wrongCode := "000000"
		if session.Code == wrongCode {
			wrongCode = "111111"
		}

		payload, _ := json.Marshal(map[string]string{"sessionId": "session_wrong_code", "code": wrongCode})
		rec := httptest.NewRecorder()
		syncPairingConfirmHandler(rec, httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(payload)))

		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for wrong pairing code, got %d: %s", rec.Code, rec.Body.String())
		}
		requireNoSyncAuthTokenPersisted(t)
	})

	t.Run("unknown session id", func(t *testing.T) {
		newTempSyncStore(t)
		payload, _ := json.Marshal(map[string]string{"sessionId": "session_never_started", "code": "123456"})
		rec := httptest.NewRecorder()
		syncPairingConfirmHandler(rec, httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(payload)))

		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for unknown session id, got %d: %s", rec.Code, rec.Body.String())
		}
		requireNoSyncAuthTokenPersisted(t)
	})

	t.Run("consumed session id", func(t *testing.T) {
		newTempSyncStore(t)
		startRec := httptest.NewRecorder()
		syncPairingStartHandler(startRec, httptest.NewRequest(http.MethodPost, "/sync/pairing/start", bytes.NewReader([]byte(`{"deviceId":"dev_air"}`))))
		if startRec.Code != http.StatusOK {
			t.Fatalf("unexpected start status %d: %s", startRec.Code, startRec.Body.String())
		}
		var started syncPairingStartResponse
		if err := json.Unmarshal(startRec.Body.Bytes(), &started); err != nil {
			t.Fatalf("decode start response: %v", err)
		}
		payload, _ := json.Marshal(map[string]string{"sessionId": started.SessionID, "code": started.Code})

		firstRec := httptest.NewRecorder()
		syncPairingConfirmHandler(firstRec, httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(payload)))
		if firstRec.Code != http.StatusOK {
			t.Fatalf("first confirm should succeed, got %d: %s", firstRec.Code, firstRec.Body.String())
		}

		// 2 回目は消費済みなので拒否される（リプレイ防止）。
		secondRec := httptest.NewRecorder()
		syncPairingConfirmHandler(secondRec, httptest.NewRequest(http.MethodPost, "/sync/pairing/confirm", bytes.NewReader(payload)))
		if secondRec.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 when replaying a consumed session id, got %d: %s", secondRec.Code, secondRec.Body.String())
		}
		settings, err := store.Instance.LoadMap("settings")
		if err != nil {
			t.Fatalf("load settings: %v", err)
		}
		tokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
		if len(tokens) != 1 {
			t.Fatalf("replayed confirm must not issue an extra token, got %#v", tokens)
		}
	})
}
