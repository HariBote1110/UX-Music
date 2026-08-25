package server

import (
	"context"
	"sync"
	"testing"
	"time"
)

// newParkTestApp mirrors newQueueTestApp (app_queue_test.go): a headless App
// with an emit spy, for exercising app_park.go's pending-intent logic
// without a real Wails runtime.
func newParkTestApp(t *testing.T) (*App, *[]struct {
	name string
	data interface{}
}) {
	t.Helper()
	emitted := &[]struct {
		name string
		data interface{}
	}{}
	// Guards appends to *emitted: TestAppParkState_ConcurrentAccess calls
	// emitOrQueueIntent (and therefore this emitter) from many goroutines
	// at once under -race, and the slice append itself is not otherwise
	// synchronised.
	var emittedMu sync.Mutex
	app := &App{
		ctx: context.Background(),
		playCountsEmitter: func(_ context.Context, name string, data interface{}) {
			emittedMu.Lock()
			defer emittedMu.Unlock()
			*emitted = append(*emitted, struct {
				name string
				data interface{}
			}{name: name, data: data})
		},
	}
	return app, emitted
}

// stubbedWebViewLifecycle overrides the package-level windowUnloadWebViewFunc/
// windowReloadWebViewFunc indirection (app_wails_adapter.go) with spies for
// the duration of the calling test, restoring the originals (headless
// no-ops) via t.Cleanup. This is the same save/restore-a-package-var pattern
// TestEventsEmitFuncWiring (app_event_emitter_wiring_test.go) uses for
// eventsEmitFunc — both exist so unit tests never reach the real Wails
// runtime (which would call log.Fatalf on a context.Context lacking a real
// Wails app, see v2/pkg/runtime/runtime.go's getFrontend).
func stubbedWebViewLifecycle(t *testing.T) (unloadCalls *int, reloadCalls *int) {
	t.Helper()
	origUnload := windowUnloadWebViewFunc
	origReload := windowReloadWebViewFunc
	t.Cleanup(func() {
		windowUnloadWebViewFunc = origUnload
		windowReloadWebViewFunc = origReload
	})
	unloadCalls = new(int)
	reloadCalls = new(int)
	var mu sync.Mutex
	windowUnloadWebViewFunc = func(context.Context) {
		mu.Lock()
		defer mu.Unlock()
		*unloadCalls++
	}
	windowReloadWebViewFunc = func(context.Context) {
		mu.Lock()
		defer mu.Unlock()
		*reloadCalls++
	}
	return unloadCalls, reloadCalls
}

// stubbedWebViewLifecycleAsync is stubbedWebViewLifecycle's counterpart for
// tests that exercise the real time.AfterFunc-driven timer
// (startParkTimer/attemptPark): it signals on a buffered channel per call
// instead of only counting, so a test can block on "did the timer actually
// fire" with select+timeout rather than a fixed sleep-then-check, which
// would otherwise be racy against the goroutine time.AfterFunc runs its
// callback on.
func stubbedWebViewLifecycleAsync(t *testing.T) (unloadCh chan struct{}, reloadCh chan struct{}) {
	t.Helper()
	origUnload := windowUnloadWebViewFunc
	origReload := windowReloadWebViewFunc
	t.Cleanup(func() {
		windowUnloadWebViewFunc = origUnload
		windowReloadWebViewFunc = origReload
	})
	unloadCh = make(chan struct{}, 8)
	reloadCh = make(chan struct{}, 8)
	windowUnloadWebViewFunc = func(context.Context) {
		unloadCh <- struct{}{}
	}
	windowReloadWebViewFunc = func(context.Context) {
		reloadCh <- struct{}{}
	}
	return unloadCh, reloadCh
}

func TestConsumePendingIntent_EmptyByDefault(t *testing.T) {
	app, _ := newParkTestApp(t)
	if intent := app.ConsumePendingIntent(); intent != nil {
		t.Fatalf("expected nil pending intent on a fresh App, got %#v", intent)
	}
}

func TestSetPendingIntent_ConsumeReturnsItAndClears(t *testing.T) {
	app, _ := newParkTestApp(t)
	payload := map[string]interface{}{"foo": "bar"}
	app.setPendingIntent("queue-play-embed", payload)

	intent := app.ConsumePendingIntent()
	if intent == nil {
		t.Fatalf("expected a pending intent, got nil")
	}
	if intent["event"] != "queue-play-embed" {
		t.Fatalf("expected event queue-play-embed, got %#v", intent["event"])
	}
	if payloadOut, ok := intent["payload"].(map[string]interface{}); !ok || payloadOut["foo"] != "bar" {
		t.Fatalf("expected payload to round-trip, got %#v", intent["payload"])
	}

	// Consuming clears the slot.
	if again := app.ConsumePendingIntent(); again != nil {
		t.Fatalf("expected nil after consuming once, got %#v", again)
	}
}

func TestSetPendingIntent_NewerIntentSupersedesOlder(t *testing.T) {
	app, _ := newParkTestApp(t)
	app.setPendingIntent("remote-play-song", "song-1")
	app.setPendingIntent("queue-play-embed", map[string]interface{}{"id": "song-2"})

	intent := app.ConsumePendingIntent()
	if intent == nil || intent["event"] != "queue-play-embed" {
		t.Fatalf("expected the newer intent to win, got %#v", intent)
	}
	if again := app.ConsumePendingIntent(); again != nil {
		t.Fatalf("expected nil after consuming once, got %#v", again)
	}
}

func TestWindowSetParked_TrueRoutesFutureIntentsToPendingSlotAndTriggersReload(t *testing.T) {
	app, emitted := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)
	app.WindowSetParked(true)

	app.emitOrQueueIntent("queue-play-embed", map[string]interface{}{"id": "song-1"})

	if hasEmit(emitted, "queue-play-embed") {
		t.Fatalf("expected queue-play-embed NOT to be emitted while parked")
	}
	// A queued intent while parked reloads the (destroyed) webview directly
	// instead of emitting a "wake-request" event that nothing is alive to
	// receive (see FORK_NOTES.md — events are safe no-ops while the webview
	// is unloaded).
	if *reloadCalls != 1 {
		t.Fatalf("expected exactly one WindowReloadWebView call, got %d", *reloadCalls)
	}
	intent := app.ConsumePendingIntent()
	if intent == nil || intent["event"] != "queue-play-embed" {
		t.Fatalf("expected the intent to be queued for later consumption, got %#v", intent)
	}
}

func TestWindowSetParked_FalseRoutesIntentsToDirectEmitAndDoesNotReload(t *testing.T) {
	app, emitted := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)
	app.WindowSetParked(true)
	app.WindowSetParked(false)

	app.emitOrQueueIntent("remote-play-song", "song-1")

	if !hasEmit(emitted, "remote-play-song") {
		t.Fatalf("expected remote-play-song to be emitted directly once unparked")
	}
	if *reloadCalls != 0 {
		t.Fatalf("expected no WindowReloadWebView call once unparked, got %d", *reloadCalls)
	}
	if intent := app.ConsumePendingIntent(); intent != nil {
		t.Fatalf("expected no pending intent once unparked, got %#v", intent)
	}
}

func TestRecordParkUIState_StoresAndConsumeClears(t *testing.T) {
	app, _ := newParkTestApp(t)

	app.RecordParkUIState("album-view", 240)

	state := app.ConsumeParkedUIState()
	if state == nil || state["viewId"] != "album-view" || state["scrollTop"] != float64(240) {
		t.Fatalf("expected the UI state to round-trip via ConsumeParkedUIState, got %#v", state)
	}
	if again := app.ConsumeParkedUIState(); again != nil {
		t.Fatalf("expected nil after consuming once, got %#v", again)
	}
}

func TestRecordParkUIState_LaterCallOverwritesEarlierOne(t *testing.T) {
	app, _ := newParkTestApp(t)

	app.RecordParkUIState("track-view", 0)
	app.RecordParkUIState("album-view", 240)

	state := app.ConsumeParkedUIState()
	if state == nil || state["viewId"] != "album-view" || state["scrollTop"] != float64(240) {
		t.Fatalf("expected the latest recorded state to win, got %#v", state)
	}
}

func TestConsumeParkedUIState_EmptyByDefault(t *testing.T) {
	app, _ := newParkTestApp(t)
	if state := app.ConsumeParkedUIState(); state != nil {
		t.Fatalf("expected nil UI state on a fresh App, got %#v", state)
	}
}

func TestWindowSetParked_FalseClearsStaleUIState(t *testing.T) {
	app, _ := newParkTestApp(t)

	app.RecordParkUIState("album-view", 10)
	// Unparking (as restoreFromPark does on every SPA boot) must discard any
	// UI state a previous park cycle left behind, exactly like it already
	// discards a stale pending intent — a leftover snapshot from an earlier
	// cycle would be a bug, not a feature (see app_park.go's doc comment).
	app.WindowSetParked(false)

	if state := app.ConsumeParkedUIState(); state != nil {
		t.Fatalf("expected WindowSetParked(false) to clear stale UI state, got %#v", state)
	}
}

func TestReloadWebViewIfParked_NoOpWhenNotParked(t *testing.T) {
	app, _ := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)

	app.reloadWebViewIfParked()

	if *reloadCalls != 0 {
		t.Fatalf("expected no WindowReloadWebView call when not parked, got %d", *reloadCalls)
	}
}

func TestReloadWebViewIfParked_ReloadsWhenParked(t *testing.T) {
	app, _ := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)
	app.WindowSetParked(true)

	app.reloadWebViewIfParked()

	if *reloadCalls != 1 {
		t.Fatalf("expected exactly one WindowReloadWebView call, got %d", *reloadCalls)
	}
}

// --- attemptPark: the Go-owned park decision (root-cause fix) ---
//
// Phase 3's first attempt kept the 15s debounce as a JS setTimeout inside
// the (about to be hidden) WebView. Re-testing found the window sitting
// hidden for 9.5 minutes with WebContent still alive and no park at all —
// WebKit suspends/throttles JS timers in hidden/occluded pages, so the
// timer could fire arbitrarily late or never. The fix moves both the
// debounce and the park decision into Go (time.AfterFunc, driven by
// NSApplicationDidHide/DidUnhide via handleAppVisibilityChanged), which is
// never subject to WebView timer throttling. These tests exercise that
// decision directly (attemptPark) and via the real timer
// (startParkTimer/cancelParkTimer, see the *_RealTimer tests further down).

func TestAttemptPark_ParksWhenHiddenAndNoEmbedActive(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCalls, _ := stubbedWebViewLifecycle(t)
	app.setHidden(true)

	app.attemptPark()

	if !app.isParked() {
		t.Fatalf("expected attemptPark to mark the app parked")
	}
	if *unloadCalls != 1 {
		t.Fatalf("expected exactly one WindowUnloadWebView call, got %d", *unloadCalls)
	}
}

func TestAttemptPark_NoOpWhenNoLongerHidden(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCalls, _ := stubbedWebViewLifecycle(t)
	app.setHidden(false)

	app.attemptPark()

	if app.isParked() {
		t.Fatalf("expected attemptPark not to park when no longer hidden")
	}
	if *unloadCalls != 0 {
		t.Fatalf("expected no WindowUnloadWebView call, got %d", *unloadCalls)
	}
}

func TestAttemptPark_NoOpWhenAlreadyParked(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCalls, _ := stubbedWebViewLifecycle(t)
	app.setHidden(true)
	app.WindowSetParked(true)

	app.attemptPark()

	if *unloadCalls != 0 {
		t.Fatalf("expected no additional WindowUnloadWebView call when already parked, got %d", *unloadCalls)
	}
}

func TestAttemptPark_NoOpWhenEmbedSessionActive(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCalls, _ := stubbedWebViewLifecycle(t)
	// withEmbedSessionActive (app_remote_embed_command_test.go) marks
	// remoteRelay active, mimicking NotifyYouTubePlaybackState(active=true)
	// — the same Go-side signal embedSessionActive() (app_remote.go) reads,
	// which is what attemptPark consults (see the doc comment above this
	// block for why: a live JS call is not an option at park-decision time).
	withEmbedSessionActive(t)
	app.setHidden(true)

	app.attemptPark()

	if app.isParked() {
		t.Fatalf("expected attemptPark not to park while an embed session is active")
	}
	if *unloadCalls != 0 {
		t.Fatalf("expected no WindowUnloadWebView call, got %d", *unloadCalls)
	}
}

// --- startParkTimer/cancelParkTimer: the real time.AfterFunc path ---

func TestStartParkTimer_FiresAttemptParkAfterDelay(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCh, _ := stubbedWebViewLifecycleAsync(t)
	app.park.mu.Lock()
	app.park.delayOverride = 10 * time.Millisecond
	app.park.mu.Unlock()
	app.setHidden(true)

	app.startParkTimer()

	select {
	case <-unloadCh:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the park timer to fire WindowUnloadWebView")
	}
	if !app.isParked() {
		t.Fatalf("expected the app to be parked once the timer fires")
	}
}

func TestCancelParkTimer_PreventsAttemptParkFromFiring(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCh, _ := stubbedWebViewLifecycleAsync(t)
	app.park.mu.Lock()
	app.park.delayOverride = 10 * time.Millisecond
	app.park.mu.Unlock()
	app.setHidden(true)

	app.startParkTimer()
	app.cancelParkTimer()

	select {
	case <-unloadCh:
		t.Fatal("expected the cancelled timer not to fire WindowUnloadWebView")
	case <-time.After(200 * time.Millisecond):
		// No fire within well over the (10ms) delay: cancellation held.
	}
	if app.isParked() {
		t.Fatalf("expected the app not to be parked after cancellation")
	}
}

func TestHandleAppVisibilityChanged_HiddenTrue_StartsParkTimerThatFires(t *testing.T) {
	app, emitted := newParkTestApp(t)
	unloadCh, _ := stubbedWebViewLifecycleAsync(t)
	app.park.mu.Lock()
	app.park.delayOverride = 10 * time.Millisecond
	app.park.mu.Unlock()

	app.handleAppVisibilityChanged(true)

	if !hasEmit(emitted, "app-visibility-changed") {
		t.Fatalf("expected app-visibility-changed to be emitted, got %#v", *emitted)
	}
	select {
	case <-unloadCh:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the park timer to fire WindowUnloadWebView")
	}
	if !app.isParked() {
		t.Fatalf("expected the app to be parked once the timer fires")
	}
}

func TestHandleAppVisibilityChanged_HiddenFalseBeforeDelay_CancelsTimer(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCh, _ := stubbedWebViewLifecycleAsync(t)
	app.park.mu.Lock()
	app.park.delayOverride = 30 * time.Millisecond
	app.park.mu.Unlock()

	app.handleAppVisibilityChanged(true)
	app.handleAppVisibilityChanged(false)

	select {
	case <-unloadCh:
		t.Fatal("expected re-showing before the delay to cancel the park timer")
	case <-time.After(200 * time.Millisecond):
		// No fire well past the (30ms) delay: quick re-show cancelled it.
	}
	if app.isParked() {
		t.Fatalf("expected the app not to be parked after a quick re-show")
	}
}

func TestHandleAppVisibilityChanged_HiddenFalseWhileParked_ReloadsWebView(t *testing.T) {
	app, emitted := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)
	app.WindowSetParked(true)

	app.handleAppVisibilityChanged(false)

	if !hasEmit(emitted, "app-visibility-changed") {
		t.Fatalf("expected app-visibility-changed to still be emitted, got %#v", *emitted)
	}
	if *reloadCalls != 1 {
		t.Fatalf("expected exactly one WindowReloadWebView call on hidden=false while parked, got %d", *reloadCalls)
	}
}

func TestHandleAppVisibilityChanged_HiddenFalseWhileNotParked_DoesNotReload(t *testing.T) {
	app, _ := newParkTestApp(t)
	_, reloadCalls := stubbedWebViewLifecycle(t)

	app.handleAppVisibilityChanged(false)

	if *reloadCalls != 0 {
		t.Fatalf("expected no WindowReloadWebView call when never parked, got %d", *reloadCalls)
	}
}

// TestAppParkState_ConcurrentAccess exercises setPendingIntent/
// ConsumePendingIntent/WindowSetParked/emitOrQueueIntent/RecordParkUIState/
// ConsumeParkedUIState/reloadWebViewIfParked/handleAppVisibilityChanged
// concurrently under -race, matching pkg/playqueue's queue_race_test.go
// precedent (see progress/native-play-queue.md's "並行安全性" section) —
// app_park.go's state is reachable from the Wails binding goroutine
// (renderer calls), the NSApplicationDid(Un)Hide observer callback (which
// now also starts/cancels a real timer), and startQueueItem/app_remote.go's
// HTTP handler goroutines.
func TestAppParkState_ConcurrentAccess(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)
	app.park.mu.Lock()
	app.park.delayOverride = time.Millisecond
	app.park.mu.Unlock()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(6)
		go func(i int) {
			defer wg.Done()
			app.WindowSetParked(i%2 == 0)
		}(i)
		go func(i int) {
			defer wg.Done()
			app.emitOrQueueIntent("queue-play-embed", i)
		}(i)
		go func() {
			defer wg.Done()
			app.ConsumePendingIntent()
		}()
		go func(i int) {
			defer wg.Done()
			app.RecordParkUIState("view", float64(i))
		}(i)
		go func() {
			defer wg.Done()
			app.ConsumeParkedUIState()
		}()
		go func(i int) {
			defer wg.Done()
			app.handleAppVisibilityChanged(i%2 == 0)
		}(i)
	}
	wg.Wait()
	// Let any timers this loop started settle before the test (and its
	// stubbedWebViewLifecycle cleanup) tears the spies down from under a
	// still-pending time.AfterFunc callback.
	app.cancelParkTimer()
}
