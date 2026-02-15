//go:build !windows

package mtp

import (
	"os"
	"syscall"
)

// suppressStderr redirects file descriptor 2 (stderr) to /dev/null and
// returns the duplicated original fd so it can be restored later.
// If the operation fails at any step the returned value is -1 and stderr
// is left unchanged.
func suppressStderr() int {
	// Duplicate the current stderr fd
	savedFd, err := syscall.Dup(2)
	if err != nil {
		return -1
	}

	devNull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		syscall.Close(savedFd)
		return -1
	}
	defer devNull.Close()

	// Point fd 2 → /dev/null
	if err := syscall.Dup2(int(devNull.Fd()), 2); err != nil {
		syscall.Close(savedFd)
		return -1
	}

	return savedFd
}

// restoreStderr restores stderr from the saved file descriptor returned
// by suppressStderr.  If savedFd is -1 the call is a no-op.
func restoreStderr(savedFd int) {
	if savedFd < 0 {
		return
	}
	_ = syscall.Dup2(savedFd, 2)
	syscall.Close(savedFd)
}
