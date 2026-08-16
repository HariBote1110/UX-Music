package server

import (
	"errors"
	"testing"

	"ux-music-sidecar/pkg/audio"
)

// withFakeRelayTapDeps swaps NotifyYouTubePlaybackState's PID lookup and tap
// start functions for fakes, restoring the real (production) ones after the
// test. Using package-level function variables mirrors relayEngine's own
// ffmpegPath injection seam (app_remote_relay.go).
func withFakeRelayTapDeps(t *testing.T, pids []int, pidsErr error, capture audio.TapCapture, startErr error) *fakeTapCapture {
	t.Helper()
	originalPIDs := relayWebKitHelperPIDs
	originalStart := relayStartProcessTap
	relayWebKitHelperPIDs = func() ([]int, error) { return pids, pidsErr }
	relayStartProcessTap = func(audio.ProcessTapTargets) (audio.TapCapture, error) { return capture, startErr }
	t.Cleanup(func() {
		relayWebKitHelperPIDs = originalPIDs
		relayStartProcessTap = originalStart
	})
	fake, _ := capture.(*fakeTapCapture)
	return fake
}

func TestNotifyYouTubePlaybackState_HeadlessModeIsNoOp(t *testing.T) {
	withServerMode(t, ModeHeadless)
	// No fake deps installed: if this reached the real audio.* calls in a
	// non-GUI-gated path it would fail loudly, so a nil error here proves
	// the headless guard short-circuited before touching them.
	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "Song", "https://example.invalid/thumb.jpg"); err != nil {
		t.Fatalf("NotifyYouTubePlaybackState() in headless mode = %v, want nil (no-op)", err)
	}
	if active, _, _ := remoteRelay.State(); active {
		t.Fatalf("remoteRelay became active from a headless-mode notify, want inert")
	}
}

func TestNotifyYouTubePlaybackState_ActiveStartsTapAndRelayWithMetadata(t *testing.T) {
	withServerMode(t, ModeGUI)
	fake := withFakeRelayTapDeps(t, []int{4242}, nil, &fakeTapCapture{sampleRate: 48000, channels: 2}, nil)
	t.Cleanup(func() { remoteRelay.Stop() })

	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "My Song", "https://example.invalid/thumb.jpg"); err != nil {
		t.Fatalf("NotifyYouTubePlaybackState(active=true) = %v, want nil", err)
	}

	active, title, thumbnail := remoteRelay.State()
	if !active {
		t.Fatalf("remoteRelay.State() active = false, want true")
	}
	if title != "My Song" || thumbnail != "https://example.invalid/thumb.jpg" {
		t.Fatalf("remoteRelay.State() title/thumbnail = %q/%q, want the notified metadata", title, thumbnail)
	}
	if fake.stopped {
		t.Fatalf("tap capture was stopped immediately after starting, want it left running while active")
	}
}

func TestNotifyYouTubePlaybackState_InactiveStopsRelayAndTap(t *testing.T) {
	withServerMode(t, ModeGUI)
	fake := withFakeRelayTapDeps(t, []int{4242}, nil, &fakeTapCapture{sampleRate: 48000, channels: 2}, nil)

	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "My Song", "thumb"); err != nil {
		t.Fatalf("NotifyYouTubePlaybackState(active=true) = %v, want nil", err)
	}
	if err := app.NotifyYouTubePlaybackState(false, "", ""); err != nil {
		t.Fatalf("NotifyYouTubePlaybackState(active=false) = %v, want nil", err)
	}

	if active, _, _ := remoteRelay.State(); active {
		t.Fatalf("remoteRelay.State() active = true after active=false notify, want false")
	}
	if !fake.stopped {
		t.Fatalf("tap capture Stop() was not called after active=false notify")
	}
}

func TestNotifyYouTubePlaybackState_NoOwnedWebKitHelperReturnsError(t *testing.T) {
	withServerMode(t, ModeGUI)
	withFakeRelayTapDeps(t, nil, nil, nil, nil)

	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "Song", "thumb"); err == nil {
		t.Fatalf("NotifyYouTubePlaybackState() with no owned WebKit helper = nil, want an error")
	}
	if active, _, _ := remoteRelay.State(); active {
		t.Fatalf("remoteRelay became active despite no tappable helper, want inert")
	}
}

func TestNotifyYouTubePlaybackState_TapStartFailurePropagatesAndLeavesRelayInactive(t *testing.T) {
	withServerMode(t, ModeGUI)
	withFakeRelayTapDeps(t, []int{4242}, nil, nil, errors.New("boom"))

	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "Song", "thumb"); err == nil {
		t.Fatalf("NotifyYouTubePlaybackState() with failing tap start = nil, want an error")
	}
	if active, _, _ := remoteRelay.State(); active {
		t.Fatalf("remoteRelay became active despite tap start failure, want inactive")
	}
}

func TestNotifyYouTubePlaybackState_RestartWhileActiveStopsPreviousTapFirst(t *testing.T) {
	withServerMode(t, ModeGUI)
	firstFake := &fakeTapCapture{sampleRate: 48000, channels: 2}
	withFakeRelayTapDeps(t, []int{1}, nil, firstFake, nil)

	app := &App{}
	if err := app.NotifyYouTubePlaybackState(true, "First", "thumb1"); err != nil {
		t.Fatalf("first NotifyYouTubePlaybackState() = %v, want nil", err)
	}

	secondFake := &fakeTapCapture{sampleRate: 48000, channels: 2}
	relayStartProcessTap = func(audio.ProcessTapTargets) (audio.TapCapture, error) { return secondFake, nil }
	t.Cleanup(func() { remoteRelay.Stop() })

	if err := app.NotifyYouTubePlaybackState(true, "Second", "thumb2"); err != nil {
		t.Fatalf("second NotifyYouTubePlaybackState() = %v, want nil", err)
	}

	if !firstFake.stopped {
		t.Fatalf("previous tap capture was not stopped when a new video started, want it stopped")
	}
	if secondFake.stopped {
		t.Fatalf("new tap capture was stopped immediately, want it left running")
	}
	_, title, _ := remoteRelay.State()
	if title != "Second" {
		t.Fatalf("remoteRelay.State() title = %q, want %q", title, "Second")
	}
}
