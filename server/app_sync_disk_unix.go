//go:build !windows

package server

import (
	"path/filepath"
	"syscall"
)

var syncAvailableFreeSpaceBytes = availableFreeSpaceBytes

func availableFreeSpaceBytes(path string) (uint64, error) {
	if path == "" {
		path = "."
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(filepath.Clean(path), &stat); err != nil {
		return 0, err
	}
	return stat.Bavail * uint64(stat.Bsize), nil
}
