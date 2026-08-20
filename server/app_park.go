// server/app_park.go implements Phase 2 of
// markdown/background-native-queue-plan.md: while the SPA is parked (its
// WebView has been navigated away to the tiny /parked.html page, see
// src/renderer/js/features/park.ts), any Go event that only a live SPA can
// act on must not simply be emitted into the void — the parked page has no
// listeners that mount an embed or resolve a song. Instead it is stashed in
// a single-slot "pending intent" that the SPA drains on its next startup
// (see queue-bridge.ts's ConsumePendingIntent() call, next to the existing
// QueueGetState() seam).
//
// This is the single choke point every renderer-directed, SPA-only event
// goes through (see emitOrQueueIntent's call sites in app_queue.go's
// startQueueItem and app_remote.go's play-song handler) so a future
// Phase 3 (Wails-fork DestroyWebView instead of navigation) only has to
// change WindowSetParked/emitOrQueueIntent, not every call site.
package server

import "sync"

// appParkState is the mutex-guarded state backing WindowSetParked/
// ConsumePendingIntent. Held as a value (not a pointer) on App, zero-value
// ready, so struct-literal-constructed Apps (as most tests in this package
// use) work without extra setup — mirrors how pkg/playqueue.Queue and its
// App-level ensureQueue() lazily-initialise wrapper are set up.
type appParkState struct {
	mu      sync.Mutex
	parked  bool
	pending *pendingIntent
}

// pendingIntent is the single {event, payload} slot: a newer intent
// supersedes an older one (see setPendingIntent), matching the design's
// "a single slot is enough" call — while parked, only the most recent
// playback request matters once the SPA returns.
type pendingIntent struct {
	event   string
	payload interface{}
}

// WindowSetParked is the Wails binding the renderer calls right before it
// navigates itself to /parked.html (parked=true) and again right after its
// next startup (parked=false, see park.ts's restore path). It does not
// itself do any parking/unparking — it only flips the flag that
// emitOrQueueIntent consults, and clears out any stale pending intent when
// re-entering the live state (a fresh QueueGetState()/ConsumePendingIntent()
// pair on startup is the sole source of truth for what to restore, so a
// leftover pending intent from a previous park cycle would be a bug, not a
// feature).
func (a *App) WindowSetParked(parked bool) {
	a.park.mu.Lock()
	defer a.park.mu.Unlock()
	a.park.parked = parked
	if !parked {
		a.park.pending = nil
	}
}

// isParked reports whether the SPA is currently parked, per the last
// WindowSetParked call. Defaults to false (never parked) for an App that
// has never had WindowSetParked called on it, e.g. headless/tests.
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

// emitOrQueueIntent is the single seam startQueueItem's "queue-play-embed"
// emit and app_remote.go's "remote-play-song" emit both route through
// instead of calling a.emit directly. While unparked it behaves exactly
// like a.emit did before Phase 2 (byte-for-byte — same event name, same
// payload). While parked it stashes the intent instead (see
// setPendingIntent) and emits a lightweight "wake-request" event so the
// parked page's listener knows to location.replace('/') back to the SPA
// (see public/parked.html) — the payload never reaches the parked page,
// which has no code to act on it; the live SPA drains it via
// ConsumePendingIntent() on its next startup instead.
func (a *App) emitOrQueueIntent(event string, payload interface{}) {
	if !a.isParked() {
		a.emit(event, payload)
		return
	}
	a.setPendingIntent(event, payload)
	a.emit("wake-request", nil)
}
