package server

import (
	"context"
	"testing"
)

// TestEmit_UsesEventsEmitFuncReassignedAfterConstruction reproduces the
// regression where wireWailsRuntime's reassignment of the package-level
// eventsEmitFunc (called after NewApp during Startup) was invisible to
// App.emit because NewApp had already captured the OLD value of
// eventsEmitFunc into the playCountsEmitter field. Since emit prefers a
// non-nil field, every event emitted after Startup silently used the stale
// no-op, dropping all GUI events (e.g. 'library-loaded').
func TestEmit_UsesEventsEmitFuncReassignedAfterConstruction(t *testing.T) {
	origEventsEmitFunc := eventsEmitFunc
	defer func() { eventsEmitFunc = origEventsEmitFunc }()

	a := NewApp()
	a.ctx = context.Background()

	// Simulate wireWailsRuntime reassigning the package-level var AFTER
	// NewApp has already run (as happens in real Startup flow).
	var received []string
	eventsEmitFunc = func(_ context.Context, name string, _ interface{}) {
		received = append(received, name)
	}

	a.emit("library-loaded", nil)

	if len(received) != 1 || received[0] != "library-loaded" {
		t.Fatalf("expected emit to reach reassigned eventsEmitFunc, got %v", received)
	}
}
