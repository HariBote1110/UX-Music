//go:build windows

package mtp

// suppressStderr is a no-op stub on Windows.
func suppressStderr() int {
	return -1
}

// restoreStderr is a no-op stub on Windows.
func restoreStderr(savedFd int) {}
