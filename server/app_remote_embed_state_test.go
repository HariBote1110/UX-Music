package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// setRelayActiveForTest flips remoteRelay's active flag directly (same
// package, so the unexported field is reachable) without needing a real
// ffmpeg-backed encode — embedSessionActive() only reads this flag.
func setRelayActiveForTest(t *testing.T, active bool) {
	t.Helper()
	remoteRelay.mu.Lock()
	remoteRelay.active = active
	remoteRelay.mu.Unlock()
	t.Cleanup(func() {
		remoteRelay.mu.Lock()
		remoteRelay.active = false
		remoteRelay.mu.Unlock()
	})
}

func TestReportEmbedPlaybackState_HeadlessModeIsNoOp(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeHeadless)
	currentEmbedPlaybackReport.Clear()

	app := NewApp()
	if err := app.ReportEmbedPlaybackState(42.0, 210.0, true); err != nil {
		t.Fatalf("ReportEmbedPlaybackState: %v", err)
	}

	if _, _, _, active := currentEmbedPlaybackReport.Get(); active {
		t.Fatalf("expected no report to be recorded in headless mode")
	}
}

func TestRemoteStateHandler_PrefersEmbedReportWhileEmbedSessionActive(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	currentEmbedPlaybackReport.Clear()
	setRelayActiveForTest(t, true)
	token := ensureDeviceAuthToken("dev_test_embed_state")

	app := NewApp()
	if err := app.ReportEmbedPlaybackState(42.5, 210.0, true); err != nil {
		t.Fatalf("ReportEmbedPlaybackState: %v", err)
	}

	ls := &LANServer{app: app}
	handler := corsMiddleware(deviceAuthMiddleware(http.HandlerFunc(ls.remoteStateHandler)))
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/state", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var status map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if pos, _ := status["position"].(float64); pos != 42.5 {
		t.Fatalf("position = %v, want 42.5", status["position"])
	}
	if dur, _ := status["duration"].(float64); dur != 210.0 {
		t.Fatalf("duration = %v, want 210.0", status["duration"])
	}
	if playing, _ := status["playing"].(bool); !playing {
		t.Fatalf("playing = %v, want true", status["playing"])
	}
}

func TestRemoteStateHandler_IgnoresEmbedReportWhenNoEmbedSessionActive(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	currentEmbedPlaybackReport.Clear()
	setRelayActiveForTest(t, false)
	token := ensureDeviceAuthToken("dev_test_embed_state_inactive")

	app := NewApp()
	// A stale report from a previous session, if it somehow survived,
	// must not leak into state while no embed session is active.
	currentEmbedPlaybackReport.Set(999, 999, true)
	t.Cleanup(currentEmbedPlaybackReport.Clear)

	ls := &LANServer{app: app}
	handler := corsMiddleware(deviceAuthMiddleware(http.HandlerFunc(ls.remoteStateHandler)))
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/state", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	var status map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if pos, _ := status["position"].(float64); pos == 999 {
		t.Fatalf("expected embed report to be ignored when no embed session is active, got position=%v", status["position"])
	}
}

func TestNotifyYouTubePlaybackState_SessionEndClearsEmbedReport(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	currentEmbedPlaybackReport.Set(42.5, 210.0, true)

	app := NewApp()
	if err := app.NotifyYouTubePlaybackState(false, "", ""); err != nil {
		t.Fatalf("NotifyYouTubePlaybackState(false): %v", err)
	}

	if _, _, _, active := currentEmbedPlaybackReport.Get(); active {
		t.Fatalf("expected embed report to be cleared when the embed session ends")
	}
}
