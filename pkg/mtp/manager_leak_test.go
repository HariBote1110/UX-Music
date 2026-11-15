//go:build !windows

// The FD count is read from /dev/fd, which does not exist on Windows.
package mtp

import (
	"errors"
	"os"
	"syscall"
	"testing"
)

func openFDCount(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/dev/fd")
	if errors.Is(err, syscall.EBADF) {
		// macOS may close a transient /dev/fd entry before ReadDir stats it.
		dir, openErr := os.Open("/dev/fd")
		if openErr != nil {
			t.Fatal(openErr)
		}
		defer dir.Close()
		names, readErr := dir.Readdirnames(-1)
		if readErr != nil {
			t.Fatal(readErr)
		}
		return len(names)
	}
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

func TestRepeatedInitialiseDoesNotLeakFDs(t *testing.T) {
	manager := NewManager()
	before := openFDCount(t)
	for i := 0; i < 40; i++ {
		if err := manager.Initialize(); err == nil {
			if err := manager.Dispose(); err != nil {
				t.Fatal(err)
			}
			t.Skip("MTP device connected; this test requires no MTP device")
		}
	}
	after := openFDCount(t)
	delta := after - before
	t.Logf("open FDs: before=%d after=%d delta=%d", before, after, delta)
	if delta > 4 {
		t.Fatalf("40 failed initialisations leaked %d FDs; want at most 4", delta)
	}
}
