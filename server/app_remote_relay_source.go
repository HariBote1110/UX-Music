package server

import (
	"sync/atomic"
	"time"

	"ux-music-sidecar/pkg/audio"
)

// relayTapPollInterval bounds how often ReadPCM re-polls an empty tap ring
// buffer. audio.TapCapture.ReadSamples is non-blocking (it returns 0 rather
// than waiting for data), whereas relayEngine.pumpPCM re-calls ReadPCM
// immediately whenever it gets n==0 — without this sleep that combination
// would spin a CPU core. See progress/remote-relay.md's 未確定 item 3.
const relayTapPollInterval = 5 * time.Millisecond

// processTapRelaySource adapts an audio.TapCapture (pull-based, non-blocking,
// darwin-only Core Audio process tap) to the RelayPCMSource contract that
// relayEngine expects. It is the real-world counterpart to the synthetic
// chanRelayPCMSource used in app_remote_relay_test.go.
//
// It never reports exhaustion (ok=false) on its own — a process tap simply
// has nothing new to report between callbacks, which is not the same as the
// source being finished. Exhaustion is instead signalled explicitly by the
// caller via Close(), once NotifyYouTubePlaybackState(active=false) decides
// playback has stopped.
type processTapRelaySource struct {
	capture audio.TapCapture
	closed  atomic.Bool
}

func newProcessTapRelaySource(capture audio.TapCapture) *processTapRelaySource {
	return &processTapRelaySource{capture: capture}
}

// ReadPCM implements RelayPCMSource. See the type doc for the exhaustion
// contract.
func (s *processTapRelaySource) ReadPCM(dst []float32) (int, bool) {
	if s.closed.Load() {
		return 0, false
	}
	n := s.capture.ReadSamples(dst)
	if n == 0 {
		// Avoid busy-looping relayEngine.pumpPCM while the tap has nothing
		// queued (e.g. between Core Audio IOProc callbacks).
		time.Sleep(relayTapPollInterval)
	}
	return n, true
}

func (s *processTapRelaySource) SampleRate() int { return s.capture.SampleRate() }
func (s *processTapRelaySource) Channels() int   { return s.capture.Channels() }

// Close marks the source exhausted so the next ReadPCM call returns
// ok=false, letting relayEngine.pumpPCM close ffmpeg's stdin and shut the
// encode pipeline down cleanly. It does not stop the underlying capture —
// pumpPCM may still be mid-ReadSamples when Close() is called from another
// goroutine, so the caller (NotifyYouTubePlaybackState) stops the capture
// itself only after the engine has torn down.
func (s *processTapRelaySource) Close() {
	s.closed.Store(true)
}
