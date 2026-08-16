package server

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// newTempRemoteStore は Remote/LAN 系テスト用に一時 userDataPath とストアを差し込み、
// 終了時に元のグローバル値へ戻す。復元しないと後続テストが前のテストの
// userDataPath / store.Instance を引き継いでしまう。
func newTempRemoteStore(t *testing.T) string {
	t.Helper()
	return newTempUserDataStore(t)
}

func TestBuildPairingURL_containsHostPortAndSecret(t *testing.T) {
	newTempRemoteStore(t)

	got := BuildPairingURL()
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "uxmusic" || u.Host != "pair" {
		t.Fatalf("unexpected pairing URL: %q", got)
	}
	if u.Query().Get("host") == "" || u.Query().Get("port") == "" {
		t.Fatalf("host/port missing: %q", got)
	}
	if u.Query().Get("secret") == "" {
		t.Fatalf("pairing URL must include a one-time secret: %q", got)
	}
	// The QR code must never embed a long-lived token directly.
	if u.Query().Get("token") != "" {
		t.Fatalf("pairing URL must not embed a raw device token: %q", got)
	}
}

func TestBuildPairingURL_hostsParamListsAllLANAddresses(t *testing.T) {
	newTempRemoteStore(t)

	got := BuildPairingURL()
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	primaryHost := u.Query().Get("host")
	hostsParam := u.Query().Get("hosts")
	if hostsParam == "" {
		t.Fatalf("pairing URL must include hosts= with all LAN addresses: %q", got)
	}
	found := false
	for _, h := range strings.Split(hostsParam, ",") {
		if h == primaryHost {
			found = true
		}
	}
	if !found {
		t.Fatalf("hosts= must include the primary host %q: %q", primaryHost, hostsParam)
	}
}

func TestBuildPairingURL_secretsAreOneTimeUse(t *testing.T) {
	newTempRemoteStore(t)

	first, err := url.Parse(BuildPairingURL())
	if err != nil {
		t.Fatal(err)
	}
	secret := first.Query().Get("secret")

	if !consumePairingRedeemSecret(secret) {
		t.Fatalf("expected first redemption to succeed")
	}
	if consumePairingRedeemSecret(secret) {
		t.Fatalf("expected secret to be single-use")
	}
}

func TestDeviceAuthMiddlewareRejectsSensitiveEndpointWithoutToken(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_test")

	nextCalled := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	})
	handler := deviceAuthMiddleware(next)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated request code=%d want=%d", rec.Code, http.StatusUnauthorized)
	}
	if nextCalled {
		t.Fatal("unauthenticated request reached sensitive handler")
	}

	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("authenticated request code=%d want=%d", rec.Code, http.StatusNoContent)
	}
	if !nextCalled {
		t.Fatal("authenticated request did not reach sensitive handler")
	}
}

func TestDeviceAuthMiddlewareAllowsQueryTokenForMediaEndpointsOnly(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_test")

	nextCalled := false
	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	}))

	// Media GET endpoint: ?token= is accepted.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/file/song-1?token="+url.QueryEscape(token), nil)
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("media endpoint with query token: code=%d want=%d", rec.Code, http.StatusNoContent)
	}
	if !nextCalled {
		t.Fatal("media endpoint with valid query token did not reach handler")
	}

	// Non-media endpoint: ?token= must NOT be accepted, only Authorization: Bearer.
	nextCalled = false
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/v1/remote/songs?token="+url.QueryEscape(token), nil)
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("non-media endpoint with query token should be rejected, got code=%d", rec.Code)
	}
	if nextCalled {
		t.Fatal("non-media endpoint accepted a query token")
	}
}

// 形式は正しいが値の違うトークンを拒否すること。
// 長さの違うトークンは ConstantTimeCompare 手前の長さチェックで弾かれるため、
// 比較そのものの拒否経路を踏ませるには同じ長さの誤りトークンが必要。
func TestDeviceAuthMiddlewareRejectsWrongToken(t *testing.T) {
	newTempRemoteStore(t)
	valid := ensureDeviceAuthToken("dev_test")
	wrong := corruptSyncToken(valid)
	if len(wrong) != len(valid) || wrong == valid {
		t.Fatalf("test setup: wrong token must be same length and different: valid=%q wrong=%q", valid, wrong)
	}

	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+wrong)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong device token, got %d", rec.Code)
	}
}

// 認証成功時、リクエストの context に一致した deviceID が付与されること。
// ハンドラ側（sidecar directive や last-seen 記録）がこの deviceID を参照する。
func TestDeviceAuthMiddlewareAttachesDeviceIDToContext(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_ctx")

	var gotDeviceID string
	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotDeviceID = deviceIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
	if gotDeviceID != "dev_ctx" {
		t.Fatalf("deviceID in context = %q, want %q", gotDeviceID, "dev_ctx")
	}
}

// 未ペアリング端末が持つトークン（このホストで発行・保存されていないトークン）は
// 形式が正しくても拒否されること。
func TestDeviceAuthMiddlewareRejectsTokenOfUnpairedDevice(t *testing.T) {
	newTempRemoteStore(t)
	_ = ensureDeviceAuthToken("dev_paired")
	unpaired := generateAuthToken()

	nextCalled := false
	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+unpaired)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unpaired device token, got %d", rec.Code)
	}
	if nextCalled {
		t.Fatal("unpaired device token reached sensitive handler")
	}
}

// X-Device-Name ヘッダーを伴う認証済みリクエストは、その名前を
// remoteDeviceNames へ自己申告として反映すること。ペアリング前に登録された
// 端末など、リダイレクト時に表示名が取得できなかったケースを救済する。
func TestDeviceAuthMiddlewareSelfReportsDeviceNameFromHeader(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_name")

	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Name", "  Yuki's iPhone  ")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
	if got := remoteDeviceNameFor("dev_name"); got != "Yuki's iPhone" {
		t.Fatalf("remoteDeviceNameFor = %q, want trimmed %q", got, "Yuki's iPhone")
	}
}

// 既に同じ名前が保存済みの場合は設定への再書き込みを行わないこと（毎回の
// ポーリングで無駄な store 書き込みが発生するのを防ぐ）。
func TestDeviceAuthMiddlewareSkipsWriteWhenDeviceNameUnchanged(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_name2")
	if err := saveRemoteDeviceName("dev_name2", "Existing Name"); err != nil {
		t.Fatalf("setup saveRemoteDeviceName: %v", err)
	}

	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Name", "Existing Name")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
	if got := remoteDeviceNameFor("dev_name2"); got != "Existing Name" {
		t.Fatalf("remoteDeviceNameFor = %q, want unchanged %q", got, "Existing Name")
	}
}

// 過度に長い名前は defensively 64 文字に切り詰めて保存すること。
func TestDeviceAuthMiddlewareTruncatesOverlongDeviceName(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_name3")

	handler := deviceAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	longName := strings.Repeat("A", 200)
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/songs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Name", longName)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
	got := remoteDeviceNameFor("dev_name3")
	if len(got) != 64 {
		t.Fatalf("remoteDeviceNameFor length = %d, want 64", len(got))
	}
}

// CORS の allowlist が X-Device-Name ヘッダーを許可すること（自己申告名を
// LAN 経由のブラウザ/WebView 系クライアントからも送れるようにするため）。
func TestCORSMiddlewareAllowsDeviceNameHeader(t *testing.T) {
	handler := corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodOptions, "/v1/remote/songs", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	allowed := rec.Header().Get("Access-Control-Allow-Headers")
	if !strings.Contains(allowed, "X-Device-Name") {
		t.Fatalf("Access-Control-Allow-Headers = %q, want it to include X-Device-Name", allowed)
	}
}
