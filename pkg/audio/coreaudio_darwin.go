//go:build darwin

package audio

/*
#cgo LDFLAGS: -framework CoreAudio -framework CoreFoundation
#include <stdlib.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

// Returns a malloc'd UTF-8 string with the current system default output
// device name. Returns NULL on error. Caller must free().
static char* ux_default_output_device_name(void) {
    AudioDeviceID deviceID = 0;
    UInt32 size = sizeof(deviceID);
    AudioObjectPropertyAddress addr;
    addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    addr.mScope    = kAudioObjectPropertyScopeGlobal;
    addr.mElement  = kAudioObjectPropertyElementMain;

    OSStatus err = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (err != noErr || deviceID == 0) {
        return NULL;
    }

    CFStringRef name = NULL;
    size = sizeof(name);
    AudioObjectPropertyAddress nameAddr;
    nameAddr.mSelector = kAudioObjectPropertyName;
    nameAddr.mScope    = kAudioObjectPropertyScopeGlobal;
    nameAddr.mElement  = kAudioObjectPropertyElementMain;

    err = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &size, &name);
    if (err != noErr || name == NULL) {
        return NULL;
    }

    CFIndex maxLen = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(name), kCFStringEncodingUTF8) + 1;
    char* buf = (char*)malloc((size_t)maxLen);
    if (buf == NULL) {
        CFRelease(name);
        return NULL;
    }
    if (!CFStringGetCString(name, buf, maxLen, kCFStringEncodingUTF8)) {
        free(buf);
        CFRelease(name);
        return NULL;
    }
    CFRelease(name);
    return buf;
}
*/
import "C"

import "unsafe"

// SystemDefaultOutputName returns the live system default output device name
// queried directly from CoreAudio, bypassing PortAudio's cached state.
// Returns "" if it cannot be obtained.
func SystemDefaultOutputName() string {
	cstr := C.ux_default_output_device_name()
	if cstr == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(cstr))
	return C.GoString(cstr)
}
