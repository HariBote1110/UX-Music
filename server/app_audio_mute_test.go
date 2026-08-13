package server

import "testing"

// TestConsumeRemoteInitiatedNext_DefaultsFalse verifies a fresh App has no
// pending remote-initiated marker (i.e. ordinary local playback stays
// unmuted by default).
func TestConsumeRemoteInitiatedNext_DefaultsFalse(t *testing.T) {
	a := &App{}
	if a.consumeRemoteInitiatedNext() {
		t.Error("consumeRemoteInitiatedNext() = true on a fresh App, want false")
	}
}

// TestMarkNextPlaybackRemoteInitiated_ConsumedOnce verifies the marker set
// by the remote-play-song flow is observed exactly once: the following
// AudioPlay/AudioStartWebViewTap call sees it, but the one after that
// (an ordinary local play) does not.
func TestMarkNextPlaybackRemoteInitiated_ConsumedOnce(t *testing.T) {
	a := &App{}
	a.MarkNextPlaybackRemoteInitiated()

	if !a.consumeRemoteInitiatedNext() {
		t.Fatal("consumeRemoteInitiatedNext() = false right after marking, want true")
	}
	if a.consumeRemoteInitiatedNext() {
		t.Error("consumeRemoteInitiatedNext() = true on second call, want false (marker must be consumed once)")
	}
}

// TestAudioIsLocalMuted_NilPlayerReturnsFalse verifies the state accessor is
// safe to call before the audio player is initialised (matches the nil-guard
// pattern used throughout app_audio.go).
func TestAudioIsLocalMuted_NilPlayerReturnsFalse(t *testing.T) {
	a := &App{}
	if a.AudioIsLocalMuted() {
		t.Error("AudioIsLocalMuted() = true with nil audioPlayer, want false")
	}
}
