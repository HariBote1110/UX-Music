//go:build darwin && cgo
// +build darwin,cgo

package portaudio

// #cgo CFLAGS: -I${SRCDIR}/portaudio/include -I${SRCDIR}/portaudio/src/common -I${SRCDIR}/portaudio/src/os/unix -I${SRCDIR}/portaudio/src/hostapi/coreaudio -DPA_USE_COREAUDIO=1 -UPA_ENABLE_DEBUG_OUTPUT -DPA_LITTLE_ENDIAN=1 -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-implicit-const-int-float-conversion
// #cgo darwin LDFLAGS: -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -framework CoreServices
import "C"
