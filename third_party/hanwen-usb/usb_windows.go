//go:build windows && cgo
// +build windows,cgo

package usb

// #cgo CFLAGS: -I${SRCDIR}/config/windows/mingw
// #cgo windows LDFLAGS: -lsetupapi -lole32 -lcfgmgr32 -ladvapi32
import "C"
