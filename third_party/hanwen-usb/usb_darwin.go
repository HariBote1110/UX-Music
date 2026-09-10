//go:build darwin && cgo
// +build darwin,cgo

package usb

// #cgo CFLAGS: -I${SRCDIR}/config/darwin
// #cgo darwin LDFLAGS: -framework IOKit -framework CoreFoundation -framework Security
import "C"
