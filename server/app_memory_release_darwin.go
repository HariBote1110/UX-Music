//go:build darwin

package server

/*
#include <malloc/malloc.h>
*/
import "C"

// releaseNativeMallocMemory asks libmalloc's default zones to return freed
// dirty pages to the OS via malloc_zone_pressure_relief(NULL, 0) — the same
// call the OS itself issues under real memory pressure, invoked here
// proactively once the app is confirmed parked (see releaseMemoryAfterPark
// in app_memory_release.go). Passing a NULL zone applies it to every
// registered zone, not just the default one; passing a goal of 0 means "do
// as much as you reasonably can" rather than targeting a specific byte
// count. This only affects the default malloc zones — it has no effect on
// Go's own heap, which debug.FreeOSMemory (called alongside this) handles
// separately.
func releaseNativeMallocMemory() {
	C.malloc_zone_pressure_relief(nil, 0)
}
