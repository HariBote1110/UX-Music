//go:build windows
// +build windows

// libusb core sources for Windows (mirrors libusb_core_unix.c).

#include "libusb/core.c"
#include "libusb/descriptor.c"
#include "libusb/hotplug.c"
#include "libusb/io.c"
#include "libusb/strerror.c"
#include "libusb/sync.c"
