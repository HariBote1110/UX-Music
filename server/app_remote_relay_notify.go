package server

import (
	"fmt"
	"sync"

	"ux-music-sidecar/pkg/audio"
)

// relayWebKitHelperPIDs and relayStartProcessTap are injection seams so
// NotifyYouTubePlaybackState's lifecycle logic can be unit-tested with a
// fake tap (app_remote_relay_notify_test.go) without Core Audio hardware —
// the same pattern relayEngine uses for ffmpegPath (app_remote_relay.go).
var (
	relayWebKitHelperPIDs = audio.WebKitHelperPIDs
	relayStartProcessTap  = audio.StartProcessTapCapture
)

// relayTapMu guards relayTapSource/relayTapCapture below. It is process-wide
// (not a field on App) for the same reason remoteRelay itself is a package
// singleton: exactly one desktop playback pipeline, and therefore at most
// one relay tap, exists per process.
var (
	relayTapMu      sync.Mutex
	relayTapSource  *processTapRelaySource
	relayTapCapture audio.TapCapture
)

// NotifyYouTubePlaybackState is the Wails-bound hook the renderer calls
// whenever the official YouTube embed player's playback state changes
// (mount/play, ended, stop) — closing the "trigger path" 未確定 item in
// progress/remote-relay.md.
//
// The embed plays inside the Wails WebView, not as a separate "YouTube
// player process", so there is nothing more specific to target than this
// app's own WebKit helper — the same targeting AudioStartWebViewTap already
// uses for local playback (server/app_audio.go). active=true (re)starts a
// process tap on that helper and feeds it into the relay engine under
// title/thumbnailURL; active=false tears both down.
//
// GUI-mode only: in headless mode (no Wails runtime, no WebView, nothing to
// tap) this is a safe no-op, matching /v1/remote/relay's own mode gate.
func (a *App) NotifyYouTubePlaybackState(active bool, title string, thumbnailURL string) error {
	if CurrentServerMode() != ModeGUI {
		return nil
	}

	relayTapMu.Lock()
	defer relayTapMu.Unlock()

	// Always tear down whatever was previously active first. This makes the
	// call idempotent regardless of the order play/pause/ended events
	// arrive in, and mirrors relayEngine.Start's own "stop the previous
	// source first" behaviour for the tap side of the pipeline.
	stopRelayTapLocked()

	if !active {
		return nil
	}

	pids, err := relayWebKitHelperPIDs()
	if err != nil {
		return fmt.Errorf("relay tap: WebKit helper enumeration failed: %w", err)
	}
	if len(pids) == 0 {
		return fmt.Errorf("relay tap: no WebKit helper process owned by this app was found to tap")
	}

	capture, err := relayStartProcessTap(audio.ProcessTapTargets{PIDs: pids})
	if err != nil {
		return fmt.Errorf("relay tap start failed: %w", err)
	}

	source := newProcessTapRelaySource(capture)
	if err := remoteRelay.Start(source, title, thumbnailURL); err != nil {
		_ = capture.Stop()
		return fmt.Errorf("relay start failed: %w", err)
	}

	relayTapSource = source
	relayTapCapture = capture
	return nil
}

// stopRelayTapLocked stops the active relay broadcast and its backing tap
// capture, if any. Safe to call when nothing is active. Caller must hold
// relayTapMu.
func stopRelayTapLocked() {
	if relayTapSource != nil {
		// Signals exhaustion so relayEngine.pumpPCM closes ffmpeg's stdin
		// and the encode pipeline shuts down cleanly, rather than us
		// yanking the capture out from under a goroutine that may still be
		// mid-ReadSamples.
		relayTapSource.Close()
		relayTapSource = nil
	}
	remoteRelay.Stop()
	if relayTapCapture != nil {
		_ = relayTapCapture.Stop()
		relayTapCapture = nil
	}
}
