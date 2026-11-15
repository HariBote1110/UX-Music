package usb

// #cgo CFLAGS: -I${SRCDIR}/libusb
// #include "libusb.h"
// extern void goUSBHotplugEvent(uintptr_t, int);
// int LIBUSB_CALL usbHotplugCallback(libusb_context *ctx, libusb_device *device, libusb_hotplug_event event, void *user_data) {
//     goUSBHotplugEvent(*(uintptr_t *)user_data, (int)event);
//     return 0;
// }
import "C"
