package server

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"ux-music-sidecar/internal/store"
)

// newTempWearStore は Wear 系テスト用に一時 userDataPath とストアを差し込み、
// 終了時に元のグローバル値へ戻す。復元しないと後続テストが前のテストの
// userDataPath / store.Instance を引き継いでしまう。
func newTempWearStore(t *testing.T) string {
	t.Helper()
	return newTempUserDataStore(t)
}

func TestWearPairingURLFromParts(t *testing.T) {
	newTempWearStore(t)

	got := wearPairingURLFromParts("192.168.0.5", "8765")
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "uxmusic" || u.Host != "pair" {
		t.Fatalf("unexpected pairing URL: %q", got)
	}
	if u.Query().Get("host") != "192.168.0.5" || u.Query().Get("port") != "8765" {
		t.Fatalf("host/port not preserved: %q", got)
	}
	if u.Query().Get("token") == "" {
		t.Fatalf("pairing URL must include an auth token: %q", got)
	}
}

func TestWearPairingURLFromParts_queryEscape(t *testing.T) {
	newTempWearStore(t)

	got := wearPairingURLFromParts("192.168.0.5&evil", "8765")
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	if u.Query().Get("host") != "192.168.0.5&evil" {
		t.Fatalf("host: %q", u.Query().Get("host"))
	}
	if u.Query().Get("token") == "" {
		t.Fatalf("token missing: %q", got)
	}
}

func TestWearAuthMiddlewareRejectsSensitiveEndpointWithoutToken(t *testing.T) {
	newTempWearStore(t)
	token := ensureWearAuthToken()

	nextCalled := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	})
	handler := wearAuthMiddleware(next)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/wear/songs", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated request code=%d want=%d", rec.Code, http.StatusUnauthorized)
	}
	if nextCalled {
		t.Fatal("unauthenticated request reached sensitive handler")
	}

	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/wear/songs?token="+url.QueryEscape(token), nil)
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("authenticated request code=%d want=%d", rec.Code, http.StatusNoContent)
	}
	if !nextCalled {
		t.Fatal("authenticated request did not reach sensitive handler")
	}
}

// 形式は正しいが値の違うトークンを 3 つの受け口すべてで拒否すること。
// 長さの違うトークンは ConstantTimeCompare 手前の長さチェックで弾かれるため、
// 比較そのものの拒否経路を踏ませるには同じ長さの誤りトークンが必要。
func TestWearAuthMiddlewareRejectsWrongToken(t *testing.T) {
	newTempWearStore(t)
	valid := ensureWearAuthToken()
	wrong := corruptSyncToken(valid)
	if len(wrong) != len(valid) || wrong == valid {
		t.Fatalf("test setup: wrong token must be same length and different: valid=%q wrong=%q", valid, wrong)
	}

	nextCalled := false
	handler := wearAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	}))

	cases := []struct {
		name    string
		prepare func(*http.Request)
	}{
		{name: "query", prepare: func(r *http.Request) { r.URL.RawQuery = "token=" + url.QueryEscape(wrong) }},
		{name: "header", prepare: func(r *http.Request) { r.Header.Set("X-UX-Music-Token", wrong) }},
		{name: "bearer", prepare: func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+wrong) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nextCalled = false
			req := httptest.NewRequest(http.MethodGet, "/wear/songs", nil)
			tc.prepare(req)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("expected 401 for wrong wear token, got %d", rec.Code)
			}
			if nextCalled {
				t.Fatal("wrong wear token reached sensitive handler")
			}
		})
	}
}

// 未ペアリング端末が持つトークン（このホストで発行・保存されていないトークン）は
// 形式が正しくても拒否されること。
func TestWearAuthMiddlewareRejectsTokenOfUnpairedDevice(t *testing.T) {
	newTempWearStore(t)
	paired := ensureWearAuthToken()
	unpaired := generateWearAuthToken()
	if unpaired == paired {
		t.Fatalf("test setup: unpaired token collided with the paired one")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	if stored, _ := settings[wearAuthTokenSettingsKey].(string); stored != paired {
		t.Fatalf("test setup: stored wear token=%q want=%q", stored, paired)
	}

	nextCalled := false
	handler := wearAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nextCalled = true
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodGet, "/wear/songs", nil)
	req.Header.Set("X-UX-Music-Token", unpaired)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unpaired device token, got %d", rec.Code)
	}
	if nextCalled {
		t.Fatal("unpaired device token reached sensitive handler")
	}
}
