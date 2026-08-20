// server/app_park.go implements Phase 3 of
// markdown/background-native-queue-plan.md: while the SPA is parked, its
// WKWebView has actually been destroyed (via the Wails fork's
// runtime.WindowUnloadWebView — see FORK_NOTES.md in
// github.com/HariBote1110/wails, branch ux-music/webview-destroy) rather
// than merely navigated to a placeholder page (Phase 2's now-removed
// parked.html). No JS is alive while parked, so:
//   - any Go event that only a live SPA can act on must not simply be
//     emitted into the void — it is stashed in a single-slot "pending
//     intent" that the SPA drains on its next startup (see
//     ConsumePendingIntent, called by park.ts's restoreFromPark next to the
//     existing QueueGetState() seam), and
//   - the SPA's small "what was I looking at" UI snapshot, previously kept
//     in sessionStorage (which died with page navigation but would now die
//     with the WebContent process itself), is handed to Go instead and
//     reclaimed via ConsumeParkedUIState.
//   - because nothing JS-side survives to notice a wake-up request, Go
//     itself must initiate the reload (reloadWebViewIfParked) instead of
//     emitting a "wake-request" event for a parked page to react to.
//
// emitOrQueueIntent is the single choke point every renderer-directed,
// SPA-only event goes through (see its call sites in app_queue.go's
// startQueueItem and app_remote.go's play-song handler), same as in Phase 2.
package server

import "sync"

// appParkState is the mutex-guarded state backing WindowSetParked/
// WindowParkWebView/ConsumePendingIntent/ConsumeParkedUIState. Held as a
// value (not a pointer) on App, zero-value ready, so struct-literal-
// constructed Apps (as most tests in this package use) work without extra
// setup — mirrors how pkg/playqueue.Queue and its App-level ensureQueue()
// lazily-initialise wrapper are set up.
type appParkState struct {
	mu      sync.Mutex
	parked  bool
	pending *pendingIntent
	// uiState is the renderer's best-effort "what was I looking at"
	// snapshot (see park.ts's captureUIState), handed to Go by
	// WindowParkWebView because the WebContent process — and therefore any
	// sessionStorage the SPA might otherwise have used — is about to be
	// torn down.
	uiState map[string]interface{}
}

// pendingIntent is the single {event, payload} slot: a newer intent
// supersedes an older one (see setPendingIntent), matching the design's
// "a single slot is enough" call — while parked, only the most recent
// playback request matters once the SPA returns.
type pendingIntent struct {
	event   string
	payload interface{}
}

// WindowParkWebView is the Wails binding the renderer calls to actually park
// itself (see park.ts's parkNow): it stashes uiState for the SPA's next
// startup to reclaim, marks the app parked (same flag WindowSetParked
// flips, exactly as if WindowSetParked(true) had also been called — callers
// do not need to call both), and — GUI mode only, nil-ctx-safe — destroys
// the platform webview via windowUnloadWebViewFunc (wired to the Wails
// fork's runtime.WindowUnloadWebView by wireWailsRuntime; a no-op in
// headless/test builds). Nothing the renderer does after calling this may
// ever run — the WebContent process backing it is going away — so this is
// deliberately fire-and-forget from the SPA's point of view.
func (a *App) WindowParkWebView(uiState map[string]interface{}) {
	a.park.mu.Lock()
	a.park.parked = true
	a.park.uiState = uiState
	a.park.mu.Unlock()

	if a.ctx == nil {
		return
	}
	windowUnloadWebViewFunc(a.ctx)
}

// ConsumeParkedUIState is the Wails binding the renderer calls once on every
// startup (see park.ts's restoreFromPark, next to ConsumePendingIntent) to
// reclaim the snapshot WindowParkWebView stashed. Returns nil (which Wails
// marshals to JS `null`) when nothing was saved — a fresh launch, or a
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
// restoreFromPark) — and, for backward-compatible symmetry with
// WindowParkWebView (which already sets parked=true itself), still accepts
// parked=true too. It only flips the flag that emitOrQueueIntent/
// reloadWebViewIfParked consult, and — when un-parking — clears out any
// stale pending intent and UI-state snapshot (a fresh QueueGetState()/
// ConsumePendingIntent()/ConsumeParkedUIState() trio on startup is the sole
// source of truth for what to restore, so leftovers from a previous park
// cycle would be a bug, not a feature).
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
// WindowSetParked/WindowParkWebView call. Defaults to false (never parked)
// for an App that has never had either called on it, e.g. headless/tests.
func (a *App) isParked() bool {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	return a.park.parked
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
// and can drain it via ConsumePendingIntent() on its next startup — unlike
// Phase 2, there is no "wake-request" event any more: the webview is
// destroyed while parked, so nothing would be alive to receive it (events
// are safe no-ops while the webview is unloaded, see FORK_NOTES.md).
func (a *App) emitOrQueueIntent(event string, payload interface{}) {
	if !a.isParked() {
		a.emit(event, payload)
		return
	}
	a.setPendingIntent(event, payload)
	a.reloadWebViewIfParked()
}
