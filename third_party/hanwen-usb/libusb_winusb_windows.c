//go:build windows
// +build windows

// WinUSB backend, kept in its own translation unit because it defines a static
// windows_open that conflicts with the one in windows_common.c.

#include "libusb/os/windows_winusb.c"
