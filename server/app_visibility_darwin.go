//go:build darwin

package server

/*
// ARC is enabled for this package via the -fobjc-arc flag declared in
// tray_darwin.go's #cgo CFLAGS (cgo concatenates CFLAGS across all files in
// a package). app_visibility_darwin.m has no manual retain/release/
// autorelease/dealloc calls, so it compiles cleanly under ARC — see
// progress/tray-arc-retain.md for the pattern this follows.
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation -framework AppKit

void ux_register_app_visibility_observer(void);
*/
import "C"

import "sync"

var (
	appVisibilityMu sync.RWMutex
	appVisibilityCB func(hidden bool)
)

// registerAppVisibilityObserver subscribes to NSApplicationDidHide/
// DidUnhide and forwards each transition to callback. Safe to call more
// than once (the underlying ObjC registration is itself idempotent); only
// the most recently registered callback receives events.
func registerAppVisibilityObserver(callback func(hidden bool)) {
	appVisibilityMu.Lock()
	appVisibilityCB = callback
	appVisibilityMu.Unlock()

	C.ux_register_app_visibility_observer()
}

//export ux_on_app_visibility_changed
func ux_on_app_visibility_changed(hidden C.int) {
	appVisibilityMu.RLock()
	callback := appVisibilityCB
	appVisibilityMu.RUnlock()
	if callback == nil {
		return
	}
	go callback(hidden != 0)
}
