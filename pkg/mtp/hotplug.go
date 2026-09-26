package mtp

import (
	"errors"
	"sync"

	"github.com/hanwen/usb"
)

var ErrHotplugUnsupported = errors.New("mtp: USB hotplug not supported on this platform")

// WatchUSB reports USB arrivals and departures until the returned stop function
// is called. The stop function is safe to call more than once.
func WatchUSB(fn func(arrived bool)) (stop func(), err error) {
	ctx := usb.NewContext()
	if !ctx.HasHotplug() {
		ctx.Exit()
		return nil, ErrHotplugUnsupported
	}
	watcher, err := ctx.WatchHotplug(func(event usb.HotplugEvent) { fn(event == usb.HotplugArrived) })
	if err != nil {
		ctx.Exit()
		return nil, err
	}
	var once sync.Once
	return func() { once.Do(func() { watcher.Stop(); ctx.Exit() }) }, nil
}
