// server/app_park.go implements Phase 3 of
// markdown/background-native-queue-plan.md: while the SPA is parked, its
// WKWebView has actually been destroyed (via the Wails fork's
// runtime.WindowUnloadWebView — see FORK_NOTES.md in
// github.com/HariBote1110/wails, branch ux-music/webview-destroy) rather
// than merely navigated to a placeholder page (an earlier, now-removed
// parked.html).
//
// ROOT-CAUSE CORRECTION (see progress/webview-parking.md's Phase 3 section):
// the first cut of this design kept the 15s "has the window really stayed
// hidden" debounce as a JS setTimeout inside park.ts, running in the very
// WebView that was about to be hidden. Independent re-testing found the
// window sitting hidden for 9.5 minutes with WebContent still fully alive
// and no park at all — WebKit suspends/throttles JS timers in
// hidden/occluded pages, so a setTimeout there can fire arbitrarily late, or
// not at all, while the window stays hidden. (This also retroactively
// explains the confusing "80-90s" and "3.5-4 minute" timings recorded
// earlier: those were not WebKit's memory-release latency, they were this
// same suspended-timer non-determinism.) The fix: the debounce and the park
// decision now live entirely in Go — startParkTimer/attemptPark below, both
// driven by handleAppVisibilityChanged (app_media.go), which itself runs off
// NSApplicationDidHide/DidUnhide (app_visibility_darwin.go/.m), a native
// notification with no WebView JS timer in its path at all.
//
// Because parking can now happen without any further round-trip to JS, two
// other things that used to be JS-initiated at park time had to move too:
//   - the SPA's small "what was I looking at" UI snapshot can no longer be
//     requested from JS when the timer fires (JS may already be suspended).
//     Instead, JS opportunistically pushes it to Go ahead of time
//     (RecordParkUIState — see park.ts) on every view change and best-effort
//     on the app-visibility-changed hidden=true event; Go just reads
//     whatever was last recorded.
//   - any Go event that only a live SPA can act on must not simply be
//     emitted into the void while parked — it is stashed in a single-slot
//     "pending intent" that the SPA drains on its next startup (see
//     ConsumePendingIntent, called by park.ts's restoreFromPark next to the
//     existing QueueGetState() seam). emitOrQueueIntent is the single choke
//     point every renderer-directed, SPA-only event goes through (see its
//     call sites in app_queue.go's startQueueItem and app_remote.go's
//     play-song handler).
package server

import (
	"sync"
	"time"
)

// defaultParkDelay is how long the window must stay hidden, with no embed
// session becoming active in the meantime, before attemptPark actually
// parks — the Go-owned equivalent of Phase 2/the first Phase 3 attempt's
// PARK_DELAY_MS, chosen for the same reason (give a quick re-show a window
// to cancel without ever parking). See appParkState.delayOverride for how
// tests shorten it.
const defaultParkDelay = 15 * time.Second

// appParkState is the mutex-guarded state backing WindowSetParked/
// RecordParkUIState/ConsumePendingIntent/ConsumeParkedUIState/
// startParkTimer/attemptPark. Held as a value (not a pointer) on App,
// zero-value ready, so struct-literal-constructed Apps (as most tests in
// this package use) work without extra setup — mirrors how
// pkg/playqueue.Queue and its App-level ensureQueue() lazily-initialise
// wrapper are set up.
type appParkState struct {
	mu      sync.Mutex
	parked  bool
	pending *pendingIntent
	// uiState is the renderer's best-effort "what was I looking at"
	// snapshot (see park.ts), kept in Go — rather than sessionStorage,
	// which dies with the WebContent process the same way the rest of the
	// SPA's JS state does — and refreshed opportunistically via
	// RecordParkUIState well before any park actually happens.
	uiState map[string]interface{}
	// hidden mirrors the app's current NSApplicationDidHide/DidUnhide state
	// (see handleAppVisibilityChanged), read by attemptPark to confirm the
	// window is still hidden when the timer fires.
	hidden bool
	// parkTimer is the in-flight time.AfterFunc scheduled by
	// startParkTimer, or nil when none is pending. Stopped and replaced by
	// every startParkTimer call, stopped and cleared by cancelParkTimer.
	parkTimer *time.Timer
	// delayOverride, when non-zero, replaces defaultParkDelay — tests set
	// this directly (same package) to a few milliseconds so timer-driven
	// tests don't have to wait out the real 15s.
	delayOverride time.Duration
}

// pendingIntent is the single {event, payload} slot: a newer intent
// supersedes an older one (see setPendingIntent), matching the design's
// "a single slot is enough" call — while parked, only the most recent
// playback request matters once the SPA returns.
type pendingIntent struct {
	event   string
	payload interface{}
}

// RecordParkUIState is the Wails binding the renderer calls opportunistically
// (see park.ts) — on every view change, and again best-effort on the
// app-visibility-changed hidden=true event — to keep Go's copy of "what was
// the user looking at" reasonably fresh. This replaced asking JS for a
// snapshot at the moment of parking: attemptPark may run at any time after
// the window goes hidden, off a Go timer with no JS involvement, so there is
// no reliable way to pull anything from JS right then. ConsumeParkedUIState
// hands back whatever was recorded last.
func (a *App) RecordParkUIState(viewID string, scrollTop float64) {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	a.park.uiState = map[string]interface{}{"viewId": viewID, "scrollTop": scrollTop}
}

// ConsumeParkedUIState is the Wails binding the renderer calls once on every
// startup (see park.ts's restoreFromPark, next to ConsumePendingIntent) to
// reclaim the snapshot RecordParkUIState last stashed. Returns nil (which
// Wails marshals to JS `null`) when nothing was saved — a fresh launch, or a
// startup that never followed a park cycle. Take-once: clears the slot.
func (a *App) ConsumeParkedUIState() map[string]interface{} {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	state := a.park.uiState
	a.park.uiState = nil
	return state
}

// WindowSetParked is the Wails binding the renderer calls right after its
// next startup following a park cycle (parked=false, see park.ts's
// restoreFromPark). It only flips the flag that emitOrQueueIntent/
// reloadWebViewIfParked/attemptPark consult, and — when un-parking — clears
// out any stale pending intent and UI-state snapshot (a fresh
// QueueGetState()/ConsumePendingIntent()/ConsumeParkedUIState() trio on
// startup is the sole source of truth for what to restore, so leftovers from
// a previous park cycle would be a bug, not a feature). parked=true is kept
// for test/binding symmetry (attemptPark itself sets the flag directly when
// it actually parks, so production code never calls WindowSetParked(true)).
func (a *App) WindowSetParked(parked bool) {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	a.park.parked = parked
	if !parked {
		a.park.pending = nil
		a.park.uiState = nil
	}
}

// isParked reports whether the SPA is currently parked, per the last
// WindowSetParked/attemptPark call. Defaults to false (never parked) for an
// App that has never had either called on it, e.g. headless/tests.
func (a *App) isParked() bool {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	return a.park.parked
}

// setHidden records the app's current NSApplicationDidHide/DidUnhide state
// (see handleAppVisibilityChanged), consulted by attemptPark to confirm the
// window is still hidden when its timer fires.
func (a *App) setHidden(hidden bool) {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	a.park.hidden = hidden
}

// startParkTimer (re)schedules attemptPark to run after the park delay
// (defaultParkDelay, or delayOverride in tests) — called by
// handleAppVisibilityChanged on hidden=true. Any previously scheduled timer
// is stopped first, so repeated hidden=true events (should they ever occur
// without an intervening hidden=false) don't stack up multiple pending
// attemptPark calls.
func (a *App) startParkTimer() {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	if a.park.parkTimer != nil {
		a.park.parkTimer.Stop()
	}
	delay := a.park.delayOverride
	if delay <= 0 {
		delay = defaultParkDelay
	}
	a.park.parkTimer = time.AfterFunc(delay, a.attemptPark)
}

// cancelParkTimer stops any in-flight startParkTimer timer — called by
// handleAppVisibilityChanged on hidden=false, which is what makes a quick
// re-show (before the delay elapses) never park: a real Go time.Timer.Stop()
// reliably prevents the callback from running (unlike the JS setTimeout this
// replaced, which WebKit could suspend and fire late instead of on the
// re-show path ever getting a chance to cancel it in time). Safe to call
// with no timer pending.
func (a *App) cancelParkTimer() {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	if a.park.parkTimer != nil {
		a.park.parkTimer.Stop()
		a.park.parkTimer = nil
	}
}

// attemptPark is startParkTimer's callback: the actual park decision and
// action, run on its own goroutine by time.AfterFunc. It parks — sets
// a.park.parked and destroys the webview via windowUnloadWebViewFunc — only
// if, at the moment the timer fires, the window is still hidden, nothing has
// already parked it, and no YouTube embed session is active. Embed activity
// is read via embedSessionActive() (app_remote.go), which reflects
// remoteRelay's state as set by NotifyYouTubePlaybackState — the Go-side
// mirror of the renderer's isEmbedPlayerActive() (youtube-embed-player.ts's
// currentSession !== null): both flip in lockstep with the same
// play/stop-embed transitions, so this is the correct signal to consult from
// Go without calling back into JS (which, per the root-cause fix above, is
// exactly what attemptPark must not depend on being responsive).
func (a *App) attemptPark() {
	a.park.mu.Lock()
	a.park.parkTimer = nil
	stillHidden := a.park.hidden
	alreadyParked := a.park.parked
	a.park.mu.Unlock()

	if !stillHidden || alreadyParked || embedSessionActive() {
		return
	}

	a.park.mu.Lock()
	a.park.parked = true
	a.park.mu.Unlock()

	if a.ctx == nil {
		return
	}
	windowUnloadWebViewFunc(a.ctx)
}

// setPendingIntent stores {event, payload} as the sole pending intent,
// overwriting whatever was there before.
func (a *App) setPendingIntent(event string, payload interface{}) {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	a.park.pending = &pendingIntent{event: event, payload: payload}
}

// ConsumePendingIntent is the Wails binding the renderer calls once on
// every startup, right after QueueGetState() (see the seam comment in
// queue-bridge.ts). It returns the stored intent as a plain map (nil when
// empty, which Wails marshals to JS `null`) and clears the slot — this is a
// take-once read, not a peek.
func (a *App) ConsumePendingIntent() map[string]interface{} {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	if a.park.pending == nil {
		return nil
	}
	intent := a.park.pending
	a.park.pending = nil
	return map[string]interface{}{
		"event":   intent.event,
		"payload": intent.payload,
	}
}

// reloadWebViewIfParked triggers the Wails fork's runtime.WindowReloadWebView
// (via windowReloadWebViewFunc) so a destroyed webview is recreated and the
// SPA boots fresh — but only while actually parked; otherwise there is
// nothing to reload (the fork's ReloadWebView is itself a no-op if a webview
// already exists, but checking here avoids a redundant main-thread dispatch
// and keeps every call site's intent explicit). Called from two places: the
// visibility observer's callback (handleAppVisibilityChanged, app_media.go)
// when the window is shown again, and emitOrQueueIntent below when a new
// intent arrives while parked — both may race each other (e.g. the user
// re-shows the window at the same moment a remote play request comes in),
// which is safe: both calls are serialised by park.mu here, and the fork's
// ReloadWebView is idempotent once the first one actually recreates the
// webview.
func (a *App) reloadWebViewIfParked() {
	a.park.mu.Lock()
	parked := a.park.parked
	a.park.mu.Unlock()
	if !parked || a.ctx == nil {
		return
	}
	windowReloadWebViewFunc(a.ctx)
}

// emitOrQueueIntent is the single seam startQueueItem's "queue-play-embed"
// emit and app_remote.go's "remote-play-song" emit both route through
// instead of calling a.emit directly. While unparked it behaves exactly
// like a.emit did before Phase 2/3 (byte-for-byte — same event name, same
// payload). While parked it stashes the intent instead (see
// setPendingIntent) and triggers reloadWebViewIfParked so the SPA comes back
// and can drain it via ConsumePendingIntent() on its next startup — there is
// no "wake-request" event: the webview is destroyed while parked, so nothing
// would be alive to receive it (events are safe no-ops while the webview is
// unloaded, see FORK_NOTES.md).
func (a *App) emitOrQueueIntent(event string, payload interface{}) {
	if !a.isParked() {
		a.emit(event, payload)
		return
	}
	a.setPendingIntent(event, payload)
	a.reloadWebViewIfParked()
}
