package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/pkg/playqueue"
)

// withEmbedSessionActive marks remoteRelay as active for the duration of the
// test, mimicking NotifyYouTubePlaybackState(active=true) without touching
// ffmpeg/Core Audio. remoteRelay.State() is what remoteCommandHandler
// consults to decide whether a transport command should target the Go
// audio.Player or the renderer's YouTube embed.
func withEmbedSessionActive(t *testing.T) {
	t.Helper()
	remoteRelay.mu.Lock()
	remoteRelay.active = true
	remoteRelay.mu.Unlock()
	t.Cleanup(remoteRelay.Stop)
}

// TestRemoteCommandHandler_EmbedActive_RoutesTransportCommandsToEmbed verifies
// that toggle/play/pause/stop/seek are emitted to the renderer as
// "remote-embed-command" (rather than driving the Go audio.Player) whenever
// an embed session is active.
func TestRemoteCommandHandler_EmbedActive_RoutesTransportCommandsToEmbed(t *testing.T) {
	newTempRemoteStore(t)
	withEmbedSessionActive(t)
	token := ensureDeviceAuthToken("dev_appletv")

	cases := []struct {
		action string
		body   string
	}{
		{"toggle", `{"action":"toggle"}`},
		{"play", `{"action":"play"}`},
		{"pause", `{"action":"pause"}`},
		{"stop", `{"action":"stop"}`},
		{"seek", `{"action":"seek","value":12.5}`},
	}

	for _, tc := range cases {
		t.Run(tc.action, func(t *testing.T) {
			app, emitted := newRemoteCommandTestApp(t)
			handler := NewLANHTTPHandler(app)

			req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader([]byte(tc.body)))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+token)
			rec := httptest.NewRecorder()

			handler.ServeHTTP(rec, req)

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
			}
			if len(*emitted) != 1 {
				t.Fatalf("expected exactly one emit, got %#v", *emitted)
			}
			if (*emitted)[0].name != "remote-embed-command" {
				t.Fatalf("expected remote-embed-command event, got %#v", (*emitted)[0])
			}
			payload, ok := (*emitted)[0].data.(map[string]interface{})
			if !ok {
				t.Fatalf("expected map payload, got %#v", (*emitted)[0].data)
			}
			if payload["action"] != tc.action {
				t.Fatalf("payload action = %#v, want %q", payload["action"], tc.action)
			}
		})
	}
}

// TestRemoteCommandHandler_EmbedActive_SeekValuePropagated ensures the numeric
// seek target survives the emit payload (not just the action string).
func TestRemoteCommandHandler_EmbedActive_SeekValuePropagated(t *testing.T) {
	newTempRemoteStore(t)
	withEmbedSessionActive(t)
	token := ensureDeviceAuthToken("dev_appletv")

	app, emitted := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"seek","value":42.5}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	payload := (*emitted)[0].data.(map[string]interface{})
	if v, ok := payload["value"].(float64); !ok || v != 42.5 {
		t.Fatalf("payload value = %#v, want 42.5", payload["value"])
	}
}

// TestRemoteCommandHandler_EmbedInactive_UsesGoPlayerUnchanged verifies the
// non-embed path is untouched: toggle/play/pause/stop/seek still drive
// ls.app.Audio* directly and never emit remote-embed-command.
func TestRemoteCommandHandler_EmbedInactive_UsesGoPlayerUnchanged(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")

	app, emitted := newRemoteCommandTestApp(t)
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"pause"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if len(*emitted) != 0 {
		t.Fatalf("expected no emit when no embed session is active, got %#v", *emitted)
	}
}

// TestRemoteCommandHandler_NextPrev_AlwaysRouteToRendererQueueRegardlessOfEmbed
// documents that, while the Go queue is inactive (the default — see
// app_queue.go's QueueSet/Active()), next/prev keep going through the
// existing "remote-command" plain-string event (renderer-side queue, see
// playback-manager.ts) whether or not an embed session is active — the
// renderer's playNextSong/playPrevSong already re-enter play()'s
// embed/local routing per song. Once something has activated the Go queue,
// next/prev are instead handled entirely in Go (QueueNext/QueuePrev) — see
// TestRemoteCommandHandler_NextPrev_RouteToGoQueueWhenActive.
func TestRemoteCommandHandler_NextPrev_AlwaysRouteToRendererQueueRegardlessOfEmbed(t *testing.T) {
	for _, embedActive := range []bool{false, true} {
		for _, action := range []string{"next", "prev"} {
			t.Run(action, func(t *testing.T) {
				newTempRemoteStore(t)
				if embedActive {
					withEmbedSessionActive(t)
				}
				token := ensureDeviceAuthToken("dev_appletv")

				app, emitted := newRemoteCommandTestApp(t)
				handler := NewLANHTTPHandler(app)

				body := []byte(`{"action":"` + action + `"}`)
				req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+token)
				rec := httptest.NewRecorder()

				handler.ServeHTTP(rec, req)

				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
				}
				if len(*emitted) != 1 || (*emitted)[0].name != "remote-command" {
					t.Fatalf("expected single remote-command emit, got %#v", *emitted)
				}
				var decoded string
				if s, ok := (*emitted)[0].data.(string); ok {
					decoded = s
				} else {
					t.Fatalf("expected string payload, got %#v", (*emitted)[0].data)
				}
				if decoded != action {
					t.Fatalf("payload = %q, want %q", decoded, action)
				}
			})
		}
	}
}

// TestRemoteCommandHandler_NextPrev_RouteToGoQueueWhenActive verifies that,
// once the Go queue has been activated (QueueSet called at least once),
// remote next/prev drive QueueNext/QueuePrev directly instead of emitting
// the legacy "remote-command" event — there is no renderer queue left to
// delegate to for this session.
func TestRemoteCommandHandler_NextPrev_RouteToGoQueueWhenActive(t *testing.T) {
	newTempRemoteStore(t)
	token := ensureDeviceAuthToken("dev_appletv")

	app, emitted := newRemoteCommandTestApp(t)
	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
	}, 0)
	*emitted = nil // discard the queue-state-changed emitted by SetQueue above
	handler := NewLANHTTPHandler(app)

	body := []byte(`{"action":"next"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/remote/command", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	for _, e := range *emitted {
		if e.name == "remote-command" {
			t.Fatalf("legacy remote-command must not be emitted once the Go queue is active, got %#v", *emitted)
		}
	}
	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() after remote next = %+v, %v; want b, true", current, ok)
	}
}
