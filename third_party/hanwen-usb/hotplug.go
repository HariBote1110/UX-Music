package usb

// #cgo CFLAGS: -I${SRCDIR}/libusb
// #include "libusb.h"
// #include <stdlib.h>
// extern int LIBUSB_CALL usbHotplugCallback(libusb_context *, libusb_device *, libusb_hotplug_event, void *);
import "C"

import (
	"fmt"
	"runtime/cgo"
	"sync"
	"sync/atomic"
	"unsafe"
)

type HotplugEvent int

const (
	HotplugArrived HotplugEvent = HotplugEvent(C.LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED)
	HotplugLeft    HotplugEvent = HotplugEvent(C.LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT)
)

type HotplugWatcher struct {
	ctx      *Context
	callback C.libusb_hotplug_callback_handle
	handle   cgo.Handle
	userData unsafe.Pointer
	stopped  atomic.Bool
	once     sync.Once
	done     chan struct{}
}

func (c *Context) HasHotplug() bool { return C.libusb_has_capability(C.LIBUSB_CAP_HAS_HOTPLUG) != 0 }

// WatchHotplug calls fn from libusb's event loop. fn must return promptly and
// must not perform synchronous USB I/O or call Stop.
func (c *Context) WatchHotplug(fn func(HotplugEvent)) (*HotplugWatcher, error) {
	handle := cgo.NewHandle(fn)
	userData := C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0))))
	*(*C.uintptr_t)(userData) = C.uintptr_t(handle)
	w := &HotplugWatcher{ctx: c, handle: handle, userData: userData, done: make(chan struct{})}
	events := C.int(C.LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED | C.LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT)
	code := C.libusb_hotplug_register_callback(c.me(), events, 0, C.LIBUSB_HOTPLUG_MATCH_ANY, C.LIBUSB_HOTPLUG_MATCH_ANY, C.LIBUSB_HOTPLUG_MATCH_ANY, (C.libusb_hotplug_callback_fn)(C.usbHotplugCallback), userData, &w.callback)
	if code != 0 {
		handle.Delete()
		C.free(userData)
		return nil, fmt.Errorf("libusb hotplug registration: %w", Error(code))
	}
	go func() {
		defer close(w.done)
		for !w.stopped.Load() {
			timeout := C.struct_timeval{tv_sec: 0, tv_usec: 250000}
			var completed C.int
			C.libusb_handle_events_timeout_completed(c.me(), &timeout, &completed)
		}
	}()
	return w, nil
}

func (w *HotplugWatcher) Stop() {
	w.once.Do(func() {
		w.stopped.Store(true)
		C.libusb_hotplug_deregister_callback(w.ctx.me(), w.callback)
		C.libusb_interrupt_event_handler(w.ctx.me())
		<-w.done
		w.handle.Delete()
		C.free(w.userData)
	})
}
