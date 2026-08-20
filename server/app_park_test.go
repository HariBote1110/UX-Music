package server

import (
	"context"
	"sync"
	"testing"
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
	// Phase 3: a queued intent while parked reloads the (destroyed) webview
	// directly instead of emitting a "wake-request" event that nothing is
	// alive to receive (see FORK_NOTES.md — events are safe no-ops while
	// the webview is unloaded).
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

func TestWindowParkWebView_SetsParkedStoresUIStateAndUnloadsWebView(t *testing.T) {
	app, _ := newParkTestApp(t)
	unloadCalls, _ := stubbedWebViewLifecycle(t)

	app.WindowParkWebView(map[string]interface{}{"viewId": "album-view", "scrollTop": float64(240)})

	if !app.isParked() {
		t.Fatalf("expected WindowParkWebView to mark the app parked")
	}
	if *unloadCalls != 1 {
		t.Fatalf("expected exactly one WindowUnloadWebView call, got %d", *unloadCalls)
	}
	state := app.ConsumeParkedUIState()
	if state == nil || state["viewId"] != "album-view" || state["scrollTop"] != float64(240) {
		t.Fatalf("expected the UI state to round-trip via ConsumeParkedUIState, got %#v", state)
	}
}

func TestConsumeParkedUIState_EmptyByDefaultAndTakeOnce(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)

	if state := app.ConsumeParkedUIState(); state != nil {
		t.Fatalf("expected nil UI state on a fresh App, got %#v", state)
	}

	app.WindowParkWebView(map[string]interface{}{"viewId": "track-view", "scrollTop": float64(0)})
	if state := app.ConsumeParkedUIState(); state == nil {
		t.Fatalf("expected a UI state after WindowParkWebView")
	}
	if state := app.ConsumeParkedUIState(); state != nil {
		t.Fatalf("expected nil after consuming once, got %#v", state)
	}
}

func TestWindowSetParked_FalseClearsStaleUIState(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)

	app.WindowParkWebView(map[string]interface{}{"viewId": "album-view", "scrollTop": float64(10)})
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

// TestAppParkState_ConcurrentAccess exercises setPendingIntent/
// ConsumePendingIntent/WindowSetParked/emitOrQueueIntent/WindowParkWebView/
// ConsumeParkedUIState/reloadWebViewIfParked concurrently under -race,
// matching pkg/playqueue's queue_race_test.go precedent (see
// progress/native-play-queue.md's "並行安全性" section) — app_park.go's
// state is reachable from the Wails binding goroutine (renderer calls),
// the NSApplicationDid(Un)Hide observer callback, and startQueueItem/
// app_remote.go's HTTP handler goroutines.
func TestAppParkState_ConcurrentAccess(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(5)
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
			app.WindowParkWebView(map[string]interface{}{"i": i})
		}(i)
		go func() {
			defer wg.Done()
			app.ConsumeParkedUIState()
		}()
	}
	wg.Wait()
}
