//go:build windows
// +build windows

// Windows platform glue for the vendored libusb. Each Windows backend file is
// compiled in its own translation unit where upstream reuses static function
// names (e.g. windows_open in both windows_common.c and windows_winusb.c).

#include "libusb/os/events_windows.c"
#include "libusb/os/threads_windows.c"
#include "libusb/os/windows_common.c"
