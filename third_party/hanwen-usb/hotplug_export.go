package usb

// #cgo CFLAGS: -I${SRCDIR}/libusb
// #include "libusb.h"
import "C"

import "runtime/cgo"

//export goUSBHotplugEvent
func goUSBHotplugEvent(handle C.uintptr_t, event C.int) {
	cgo.Handle(handle).Value().(func(HotplugEvent))(HotplugEvent(event))
}
