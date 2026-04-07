//go:build darwin

package server

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation -framework AppKit -framework MediaPlayer
#include <stdlib.h>

void ux_register_media_commands(void);
void ux_set_now_playing(const char* title, const char* artist, const char* album, const char* artworkPath, int isPlaying);
void ux_clear_now_playing(void);
*/
import "C"

import (
	"sync"
	"unsafe"
)

const (
	mediaCommandPlay     = 1
	mediaCommandPause    = 2
	mediaCommandToggle   = 3
	mediaCommandNext     = 4
	mediaCommandPrevious = 5
	mediaCommandStop     = 6
)

var (
	osMediaCommandMu sync.RWMutex
	osMediaCommandCB func(string)
)

func registerOSMediaCommands(callback func(string)) error {
	osMediaCommandMu.Lock()
	osMediaCommandCB = callback
	osMediaCommandMu.Unlock()

	C.ux_register_media_commands()
	return nil
}

func setOSNowPlaying(title string, artist string, album string, artworkPath string, playing bool) {
	cTitle := C.CString(title)
	cArtist := C.CString(artist)
	cAlbum := C.CString(album)
	cArtworkPath := C.CString(artworkPath)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cArtist))
	defer C.free(unsafe.Pointer(cAlbum))
	defer C.free(unsafe.Pointer(cArtworkPath))

	isPlaying := C.int(0)
	if playing {
		isPlaying = 1
	}
	C.ux_set_now_playing(cTitle, cArtist, cAlbum, cArtworkPath, isPlaying)
}

func clearOSNowPlaying() {
	C.ux_clear_now_playing()
}

func mapOSMediaCommand(command int) (string, bool) {
	switch command {
	case mediaCommandPlay:
		return "play", true
	case mediaCommandPause:
		return "pause", true
	case mediaCommandToggle:
		return "toggle", true
	case mediaCommandNext:
		return "next", true
	case mediaCommandPrevious:
		return "previous", true
	case mediaCommandStop:
		return "stop", true
	default:
		return "", false
	}
}

//export ux_on_media_command
func ux_on_media_command(command C.int) {
	mapped, ok := mapOSMediaCommand(int(command))
	if !ok {
		return
	}

	osMediaCommandMu.RLock()
	callback := osMediaCommandCB
	osMediaCommandMu.RUnlock()
	if callback == nil {
		return
	}

	go callback(mapped)
}
