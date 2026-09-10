//go:build windows && cgo
// +build windows,cgo

package portaudio

// #cgo CFLAGS: -I${SRCDIR}/portaudio/include -I${SRCDIR}/portaudio/src/common -I${SRCDIR}/portaudio/src/os/win -I${SRCDIR}/portaudio/src/hostapi/wasapi -I${SRCDIR}/portaudio/src/hostapi/wmme -DPA_USE_WASAPI=1 -DPA_USE_WMME=1 -UPA_ENABLE_DEBUG_OUTPUT -DPA_LITTLE_ENDIAN=1 -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-implicit-const-int-float-conversion
// #cgo windows LDFLAGS: -lwinmm -lole32 -luuid -lksuser -lsetupapi -lavrt
import "C"
