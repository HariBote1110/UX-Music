//go:build darwin

package server

/*
// ARC is required here: tray_darwin.m is written in ARC style (no manual
// retain/release/autorelease calls), but cgo compiles Objective-C sources
// under MRC unless -fobjc-arc is passed. Without it, the autoreleased
// NSStatusItem returned by statusItemWithLength: is deallocated as soon as
// the enclosing autorelease pool drains, and the menu-bar tray icon never
// appears. #cgo CFLAGS apply package-wide (see os_media_darwin.go), so this
// single line also arcifies os_media_darwin.m, which has been verified to
// be ARC-safe.
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit
#include <stdlib.h>

void ux_tray_create(const char* iconBytes, int iconLength);
void ux_tray_set_playpause_label(const char* label);
void ux_tray_destroy(void);
*/
import "C"

import (
	_ "embed"
	"sync"
	"unsafe"
)

//go:embed assets/tray_icon_template.png
var trayIconPNG []byte

var (
	trayCommandMu sync.RWMutex
	trayCommandCB func(int)
)

// createTray builds the NSStatusItem menu-bar icon and menu. It does not
// touch NSApplication's delegate (unlike some third-party systray
// libraries), so it cannot interfere with Wails' own delegate that backs
// HideWindowOnClose / Cmd+Q handling. See progress/menubar-tray-mode.md.
func createTray(callback func(int)) {
	trayCommandMu.Lock()
	trayCommandCB = callback
	trayCommandMu.Unlock()

	iconPtr := (*C.char)(unsafe.Pointer(&trayIconPNG[0]))
	C.ux_tray_create(iconPtr, C.int(len(trayIconPNG)))
}

func setTrayPlayPauseLabel(label string) {
	cLabel := C.CString(label)
	defer C.free(unsafe.Pointer(cLabel))
	C.ux_tray_set_playpause_label(cLabel)
}

func destroyTray() {
	C.ux_tray_destroy()
}

//export ux_on_tray_command
func ux_on_tray_command(command C.int) {
	trayCommandMu.RLock()
	callback := trayCommandCB
	trayCommandMu.RUnlock()
	if callback == nil {
		return
	}
	go callback(int(command))
}
