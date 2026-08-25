package server

import (
	"runtime/debug"
	"time"
)

// defaultMemoryReleaseDelay is how long after a successful attemptPark the
// memory-return pass (releaseMemoryAfterPark) runs — deliberately off the
// park path itself (see attemptPark in app_park.go), so the WebView-destroy
// call is never blocked on it. Chosen to give the destroyed WebView's own
// teardown (WKWebView/WebContent process release) a head start before Go
// forces a GC + native malloc pressure relief pass; see
// go_memory_research/notes/park-memory-release.md for the measurements this
// value and lever were validated against.
const defaultMemoryReleaseDelay = 2 * time.Second

// memoryReleaseFunc is the package-level indirection attemptPark's
// time.AfterFunc calls, overridden by tests the same way
// windowUnloadWebViewFunc/windowReloadWebViewFunc are (see
// stubbedWebViewLifecycle in app_park_test.go and the memory-release tests
// in app_memory_release_test.go).
var memoryReleaseFunc = releaseMemoryAfterPark

// nativeMallocReleaseFunc is the package-level indirection
// releaseMemoryAfterPark calls for the native-malloc half of the L1 lever —
// backed by releaseNativeMallocMemory (malloc_zone_pressure_relief on
// darwin, a no-op on every other platform; see app_memory_release_darwin.go
// / app_memory_release_other.go). Overridden by tests so the darwin-only
// cgo call itself never needs to run under `go test`.
var nativeMallocReleaseFunc = releaseNativeMallocMemory

// releaseMemoryAfterPark is L1 (see
// go_memory_research/notes/park-memory-release.md): a best-effort attempt to
// hand idle memory back to the OS once the app is confirmed parked
// (WebView destroyed, window hidden). It combines two independent
// mechanisms, each returning a different pool:
//   - debug.FreeOSMemory() forces a GC cycle and then immediately returns
//     idle Go heap spans to the OS (skipping the scavenger's normal, much
//     slower pacing) — targets the "HeapIdle − HeapReleased" slack
//     identified in go-heap-pprof.md.
//   - nativeMallocReleaseFunc targets native (non-Go) malloc's small/large
//     zones, which Go's GC has no visibility into at all.
//
// Both are advisory to the OS (e.g. madvise under the hood) rather than
// guaranteed-immediate: macOS may delay reclaiming the pages until it is
// actually under memory pressure, so the effect on `footprint` is not
// assumed here — it is measured per-variant in park-memory-release.md.
func releaseMemoryAfterPark() {
	debug.FreeOSMemory()
	nativeMallocReleaseFunc()
}
