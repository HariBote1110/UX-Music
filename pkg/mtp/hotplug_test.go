package mtp

import (
	"runtime"
	"testing"
)

func TestWatchUSBDoesNotLeakFDs(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("hotplug unavailable")
	}
	before := openFDCount(t)
	for i := 0; i < 20; i++ {
		stop, err := WatchUSB(func(bool) {})
		if err != nil {
			t.Fatal(err)
		}
		stop()
		stop()
	}
	after := openFDCount(t)
	if after-before > 4 {
		t.Fatalf("20 watches leaked %d FDs", after-before)
	}
}
