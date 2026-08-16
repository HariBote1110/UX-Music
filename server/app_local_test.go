package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLocalShutdownLoopbackOnlyInHeadlessMode(t *testing.T) {
	newTempSyncStore(t)
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeHeadless)

	triggered := false
	restore := setHeadlessShutdownTriggerForTest(func() { triggered = true })
	defer restore()

	handler := NewLANHTTPHandler(NewApp())

	// Non-loopback remote address must be treated as if the route does not exist.
	nonLoopback := httptest.NewRequest(http.MethodPost, "/v1/local/shutdown", nil)
	nonLoopback.RemoteAddr = "203.0.113.5:12345"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, nonLoopback)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for non-loopback request, got %d", rec.Code)
	}
	if triggered {
		t.Fatalf("shutdown must not trigger for a non-loopback request")
	}

	// Loopback remote address should trigger shutdown.
	loopback := httptest.NewRequest(http.MethodPost, "/v1/local/shutdown", nil)
	loopback.RemoteAddr = "127.0.0.1:54321"
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, loopback)
	if rec2.Code != http.StatusOK {
		t.Fatalf("expected 200 for loopback headless request, got %d", rec2.Code)
	}
	if !triggered {
		t.Fatalf("expected shutdown trigger to be invoked for loopback request")
	}
}

func TestLocalShutdownNotReachableInGUIMode(t *testing.T) {
	newTempSyncStore(t)
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeGUI)

	triggered := false
	restore := setHeadlessShutdownTriggerForTest(func() { triggered = true })
	defer restore()

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodPost, "/v1/local/shutdown", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 in gui mode, got %d", rec.Code)
	}
	if triggered {
		t.Fatalf("shutdown must not trigger in gui mode")
	}
}
