//go:build linux && cgo
// +build linux,cgo

package portaudio

// #cgo CFLAGS: -I${SRCDIR}/portaudio/include -I${SRCDIR}/portaudio/src/common -I${SRCDIR}/portaudio/src/os/unix -I${SRCDIR}/portaudio/src/hostapi/alsa -DPA_USE_ALSA=1 -UPA_ENABLE_DEBUG_OUTPUT -DPA_LITTLE_ENDIAN=1 -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-implicit-const-int-float-conversion
// #cgo linux LDFLAGS: -lasound -lm -lpthread
import "C"
