package server

import "sync"

// embedPlaybackReport holds the last position/duration/playing state the
// renderer's embed (YouTube IFrame) player reported via
// ReportEmbedPlaybackState. During an embed session the Go audio.Player is
// idle — the renderer's IFrame player is what is actually sounding, relayed
// over LAN via remoteRelay — so AudioGetStatus's position/duration/playing
// would otherwise read as 0/0/false. remoteStateHandler prefers this report
// while embedSessionActive() so TV/mobile clients see real seek-bar data.
type embedPlaybackReport struct {
	mu       sync.Mutex
	active   bool
	position float64
	duration float64
	playing  bool
}

// currentEmbedPlaybackReport is a package-level singleton for the same
// reason remoteRelay is: exactly one desktop playback pipeline (and
// therefore at most one embed session) exists per process.
var currentEmbedPlaybackReport = &embedPlaybackReport{}

// Set records a fresh report. Called ~1x/second by ReportEmbedPlaybackState
// while an embed session is active, plus on pause/seek.
func (r *embedPlaybackReport) Set(position, duration float64, playing bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.active = true
	r.position = position
	r.duration = duration
	r.playing = playing
}

// Clear discards the report. Called when the embed session ends
// (NotifyYouTubePlaybackState(false, ...)) so a stale position from the
// last embed song never leaks into a later Go-player (local file) session.
func (r *embedPlaybackReport) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.active = false
	r.position = 0
	r.duration = 0
	r.playing = false
}

// Get returns the last report and whether one has been set since the last
// Clear.
func (r *embedPlaybackReport) Get() (position, duration float64, playing, active bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.position, r.duration, r.playing, r.active
}

// ReportEmbedPlaybackState is the Wails-bound hook the renderer calls while
// a YouTube official embed session is active (features/player.ts's
// startGoStatePolling tick, which already reads embedGetCurrentTime /
// embedGetDuration / embedIsPlaying every ~1s, plus explicit calls on
// pause/seek) so that GET /v1/remote/state's root position/duration/playing
// reflect the embed instead of the idle Go audio.Player.
//
// GUI-mode only, mirroring NotifyYouTubePlaybackState: in headless mode
// there is no WebView/embed player to report from, so this is a safe no-op.
func (a *App) ReportEmbedPlaybackState(position, duration float64, playing bool) error {
	if CurrentServerMode() != ModeGUI {
		return nil
	}
	currentEmbedPlaybackReport.Set(
		sanitizeFiniteFloat64(position),
		sanitizeFiniteFloat64(duration),
		playing,
	)
	return nil
}
