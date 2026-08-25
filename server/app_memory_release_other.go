//go:build !darwin

package server

// releaseNativeMallocMemory is a no-op on non-darwin platforms:
// malloc_zone_pressure_relief is a Darwin-only libmalloc API with no direct
// equivalent exposed here. See app_memory_release_darwin.go for the darwin
// implementation and app_memory_release.go for the caller.
func releaseNativeMallocMemory() {}
