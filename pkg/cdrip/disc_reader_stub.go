//go:build !darwin

package cdrip

import (
	"fmt"
	"runtime"
)

func openNativeDisc() (DiscReader, error) {
	return nil, fmt.Errorf("native CD-DA reader is not supported on %s", runtime.GOOS)
}

func DiscoverNativeDiscDevices() ([]NativeDiscDevice, error) {
	return nil, fmt.Errorf("native CD-DA reader is not supported on %s", runtime.GOOS)
}
