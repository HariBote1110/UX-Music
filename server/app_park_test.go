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

func TestWindowSetParked_TrueRoutesFutureIntentsToPendingSlot(t *testing.T) {
	app, emitted := newParkTestApp(t)
	app.WindowSetParked(true)

	app.emitOrQueueIntent("queue-play-embed", map[string]interface{}{"id": "song-1"})

	if hasEmit(emitted, "queue-play-embed") {
		t.Fatalf("expected queue-play-embed NOT to be emitted while parked")
	}
	if !hasEmit(emitted, "wake-request") {
		t.Fatalf("expected a wake-request event to be emitted while parked")
	}
	intent := app.ConsumePendingIntent()
	if intent == nil || intent["event"] != "queue-play-embed" {
		t.Fatalf("expected the intent to be queued for later consumption, got %#v", intent)
	}
}

func TestWindowSetParked_FalseRoutesIntentsToDirectEmit(t *testing.T) {
	app, emitted := newParkTestApp(t)
	app.WindowSetParked(true)
	app.WindowSetParked(false)

	app.emitOrQueueIntent("remote-play-song", "song-1")

	if !hasEmit(emitted, "remote-play-song") {
		t.Fatalf("expected remote-play-song to be emitted directly once unparked")
	}
	if hasEmit(emitted, "wake-request") {
		t.Fatalf("did not expect a wake-request once unparked")
	}
	if intent := app.ConsumePendingIntent(); intent != nil {
		t.Fatalf("expected no pending intent once unparked, got %#v", intent)
	}
}

// TestAppParkState_ConcurrentAccess exercises setPendingIntent/
// ConsumePendingIntent/WindowSetParked/emitOrQueueIntent concurrently under
// -race, matching pkg/playqueue's queue_race_test.go precedent (see
// progress/native-play-queue.md's "並行安全性" section) — app_park.go's
// state is reachable from the Wails binding goroutine (renderer calls),
// the NSApplicationDid(Un)Hide observer callback, and startQueueItem/
// app_remote.go's HTTP handler goroutines.
func TestAppParkState_ConcurrentAccess(t *testing.T) {
	app, _ := newParkTestApp(t)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(3)
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
	}
	wg.Wait()
}
