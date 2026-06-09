package server

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

func TestWearPairingURLFromParts(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "ux-music-wear-auth-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

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
	tmpDir, err := os.MkdirTemp("", "ux-music-wear-auth-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

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
	tmpDir, err := os.MkdirTemp("", "ux-music-wear-auth-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}
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
