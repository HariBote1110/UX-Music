package usb

import (
	"runtime"
	"testing"
	"time"
)

func TestHotplugWatcherStop(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("hotplug unavailable")
	}
	ctx := NewContext()
	defer ctx.Exit()
	if runtime.GOOS == "darwin" && !ctx.HasHotplug() {
		t.Fatal("darwin hotplug unavailable")
	}
	watcher, err := ctx.WatchHotplug(func(HotplugEvent) {})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { watcher.Stop(); watcher.Stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Stop exceeded one second")
	}
}
