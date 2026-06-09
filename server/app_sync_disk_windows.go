//go:build windows

package server

import (
	"path/filepath"
	"syscall"
	"unsafe"
)

var syncAvailableFreeSpaceBytes = availableFreeSpaceBytes

func availableFreeSpaceBytes(path string) (uint64, error) {
	if path == "" {
		path = "."
	}
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	getDiskFreeSpaceEx := kernel32.NewProc("GetDiskFreeSpaceExW")
	pathPtr, err := syscall.UTF16PtrFromString(filepath.Clean(path))
	if err != nil {
		return 0, err
	}
	var freeBytesAvailable uint64
	result, _, callErr := getDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(pathPtr)),
		uintptr(unsafe.Pointer(&freeBytesAvailable)),
		0,
		0,
	)
	if result == 0 {
		return 0, callErr
	}
	return freeBytesAvailable, nil
}
