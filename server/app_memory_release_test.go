package server

import (
	"testing"
	"time"
)

// TestAttemptPark_SchedulesMemoryReleaseAfterDelay exercises the L1 memory
// -return lever (see go_memory_research/notes/park-memory-release.md): a
// successful attemptPark schedules releaseMemoryAfterPark (via the
// memoryReleaseFunc indirection, overridden here the same way
// windowUnloadWebViewFunc/windowReloadWebViewFunc are stubbed in
// app_park_test.go) to run a short delay later, off the park path itself.
func TestAttemptPark_SchedulesMemoryReleaseAfterDelay(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)
	app.setHidden(true)

	origFunc := memoryReleaseFunc
	t.Cleanup(func() { memoryReleaseFunc = origFunc })
	releaseCh := make(chan struct{}, 1)
	memoryReleaseFunc = func() { releaseCh <- struct{}{} }

	app.park.mu.Lock()
	app.park.memoryReleaseDelayOverride = 10 * time.Millisecond
	app.park.mu.Unlock()

	app.attemptPark()

	select {
	case <-releaseCh:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the post-park memory release pass to run")
	}
}

// TestAttemptPark_DoesNotScheduleMemoryReleaseWhenParkDoesNotHappen confirms
// the release pass is tied to an actual park (not scheduled speculatively) —
// mirrors TestAttemptPark_NoOpWhenNoLongerHidden's setup in app_park_test.go.
func TestAttemptPark_DoesNotScheduleMemoryReleaseWhenParkDoesNotHappen(t *testing.T) {
	app, _ := newParkTestApp(t)
	stubbedWebViewLifecycle(t)
	app.setHidden(false)

	origFunc := memoryReleaseFunc
	t.Cleanup(func() { memoryReleaseFunc = origFunc })
	releaseCh := make(chan struct{}, 1)
	memoryReleaseFunc = func() { releaseCh <- struct{}{} }

	app.park.mu.Lock()
	app.park.memoryReleaseDelayOverride = 10 * time.Millisecond
	app.park.mu.Unlock()

	app.attemptPark()

	select {
	case <-releaseCh:
		t.Fatal("expected no memory release pass when attemptPark did not actually park")
	case <-time.After(100 * time.Millisecond):
	}
}

// TestReleaseMemoryAfterPark_CallsNativeMallocRelease exercises the
// cross-platform half of releaseMemoryAfterPark: it must invoke the
// platform-specific native malloc release hook (nativeMallocReleaseFunc,
// backed by malloc_zone_pressure_relief on darwin, a no-op elsewhere) in
// addition to runtime/debug.FreeOSMemory (which has no directly observable
// return value worth asserting on here).
func TestReleaseMemoryAfterPark_CallsNativeMallocRelease(t *testing.T) {
	origFunc := nativeMallocReleaseFunc
	t.Cleanup(func() { nativeMallocReleaseFunc = origFunc })
	called := false
	nativeMallocReleaseFunc = func() { called = true }

	releaseMemoryAfterPark()

	if !called {
		t.Fatal("expected releaseMemoryAfterPark to invoke nativeMallocReleaseFunc")
	}
}
