//go:build linux && cgo
// +build linux,cgo

package usb

// #cgo CFLAGS: -I${SRCDIR}/config/linux
import "C"
