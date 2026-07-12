//go:build darwin

package audio

/*
#cgo LDFLAGS: -framework Foundation -framework CoreAudio -framework AudioToolbox
#include <stdlib.h>
#include "processtap_darwin.h"
*/
import "C"

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"unsafe"
)

// processTapRegistry maps a capture ID to its ProcessTapCapture so the C
// IOProc callback (which only carries a uintptr) can find the Go object.
var (
	processTapRegistry sync.Map
	processTapNextID   atomic.Uint64
)

// ProcessTapCapture captures the audio of selected processes through a Core
// Audio process tap and buffers interleaved float32 samples in a lock-free
// ring for pull-based consumption (implements liveSampleSource).
//
// Device-change note: the aggregate device binds to the default output
// device present at Start time. When the system default output changes, the
// capture must be rebuilt — call Stop, then StartProcessTap(capture.Targets())
// again. Targets() exposes the original request precisely for such hooks.
type ProcessTapCapture struct {
	id         uintptr
	targets    ProcessTapTargets
	tap        C.AudioObjectID
	aggregate  C.AudioObjectID
	ioProcID   C.AudioDeviceIOProcID
	ring       *floatRingBuffer
	sampleRate int
	channels   int
	stopped    atomic.Bool
}

//export uxGoProcessTapSamples
func uxGoProcessTapSamples(clientID C.uintptr_t, samples *C.float, frames C.int, channels C.int) {
	value, ok := processTapRegistry.Load(uintptr(clientID))
	if !ok {
		return
	}
	capture, ok := value.(*ProcessTapCapture)
	if !ok {
		return
	}
	n := int(frames) * int(channels)
	if n <= 0 {
		return
	}
	src := unsafe.Slice((*float32)(unsafe.Pointer(samples)), n)
	capture.ring.Write(src)
}

// ProcessTapBundleAPISupported reports whether the running OS supports
// bundle-ID targeting on CATapDescription (macOS 26+).
func ProcessTapBundleAPISupported() bool {
	return C.uxTapBundleAPISupported() != 0
}

// tapStatusString renders an OSStatus (or kUXTapErr* value) readably,
// decoding printable four-char codes like the spike did.
func tapStatusString(status C.OSStatus) string {
	switch status {
	case C.kUXTapErrNoTargets:
		return "no tappable target processes found"
	case C.kUXTapErrBundleAPIUnavailable:
		return "bundle-ID tap API unavailable on this OS"
	}
	code := uint32(status)
	fourCC := []byte{byte(code >> 24), byte(code >> 16), byte(code >> 8), byte(code)}
	printable := true
	for _, b := range fourCC {
		if b < 0x20 || b > 0x7e {
			printable = false
			break
		}
	}
	if printable {
		return fmt.Sprintf("%d ('%s')", int32(status), string(fourCC))
	}
	return fmt.Sprintf("%d", int32(status))
}

// cTapTargets converts normalised targets to C arrays. The returned cleanup
// function frees all allocations.
func cTapTargets(targets ProcessTapTargets) (**C.char, C.int, *C.int, C.int, func()) {
	var bundlePtr **C.char
	var cStrings []*C.char
	if len(targets.BundleIDs) > 0 {
		cStrings = make([]*C.char, len(targets.BundleIDs))
		for i, bundleID := range targets.BundleIDs {
			cStrings[i] = C.CString(bundleID)
		}
		bundlePtr = &cStrings[0]
	}

	var pidPtr *C.int
	var cPIDs []C.int
	if len(targets.PIDs) > 0 {
		cPIDs = make([]C.int, len(targets.PIDs))
		for i, pid := range targets.PIDs {
			cPIDs[i] = C.int(pid)
		}
		pidPtr = &cPIDs[0]
	}

	cleanup := func() {
		for _, s := range cStrings {
			C.free(unsafe.Pointer(s))
		}
	}
	return bundlePtr, C.int(len(targets.BundleIDs)), pidPtr, C.int(len(targets.PIDs)), cleanup
}

// StartProcessTap creates a process tap for the given targets, wires it to a
// private aggregate device and starts capturing. Bundle-ID targeting via the
// macOS 26 API is preferred (it survives helper relaunches through
// processRestoreEnabled); otherwise processes are resolved by enumerating
// Core Audio process objects and matching bundle IDs / PIDs.
func StartProcessTap(targets ProcessTapTargets) (*ProcessTapCapture, error) {
	normalised, err := normaliseTapTargets(targets)
	if err != nil {
		return nil, err
	}

	bundlePtr, bundleCount, pidPtr, pidCount, cleanup := cTapTargets(normalised)
	defer cleanup()

	var tap C.AudioObjectID
	usedBundleAPI := false
	if bundleCount > 0 {
		if status := C.uxTapCreateWithBundleIDs(bundlePtr, bundleCount, pidPtr, pidCount, &tap); status == 0 {
			usedBundleAPI = true
		} else {
			fmt.Printf("[Audio] Process tap: bundle-ID API path unavailable (%s) — falling back to process lookup\n", tapStatusString(status))
			tap = 0
		}
	}
	if tap == 0 {
		if status := C.uxTapCreateByProcessLookup(bundlePtr, bundleCount, pidPtr, pidCount, &tap); status != 0 {
			return nil, fmt.Errorf("process tap creation failed: %s", tapStatusString(status))
		}
	}

	capture := &ProcessTapCapture{
		targets:    normalised,
		tap:        tap,
		sampleRate: 48000,
		channels:   2,
	}

	var sampleRate C.double
	var channels C.uint
	if status := C.uxTapGetFormat(tap, &sampleRate, &channels); status == 0 && sampleRate > 0 && channels > 0 {
		capture.sampleRate = int(sampleRate)
		capture.channels = int(channels)
	} else if status != 0 {
		fmt.Printf("[Audio] Process tap: format query failed (%s) — assuming 48kHz/2ch\n", tapStatusString(status))
	}

	// Two seconds of buffering absorbs scheduling jitter between the Core
	// Audio real-time thread and the player's decoder goroutine.
	capture.ring = newFloatRingBuffer(capture.sampleRate * capture.channels * 2)

	capture.id = uintptr(processTapNextID.Add(1))
	processTapRegistry.Store(capture.id, capture)

	uid := C.CString(fmt.Sprintf("ux-music-tap-%d-%d", os.Getpid(), capture.id))
	defer C.free(unsafe.Pointer(uid))
	if status := C.uxTapCreateAggregate(tap, uid, &capture.aggregate); status != 0 {
		capture.teardown()
		return nil, fmt.Errorf("process tap aggregate device creation failed: %s", tapStatusString(status))
	}
	if status := C.uxTapStartIO(capture.aggregate, C.uintptr_t(capture.id), &capture.ioProcID); status != 0 {
		capture.teardown()
		return nil, fmt.Errorf("process tap IO start failed: %s", tapStatusString(status))
	}

	fmt.Printf("[Audio] Process tap started (bundleAPI=%v, %dHz/%dch, bundles=%v, pids=%v)\n",
		usedBundleAPI, capture.sampleRate, capture.channels, normalised.BundleIDs, normalised.PIDs)
	return capture, nil
}

// ReadSamples copies up to len(dst) captured samples without blocking.
func (c *ProcessTapCapture) ReadSamples(dst []float32) int {
	return c.ring.Read(dst)
}

// SampleRate returns the tap's sample rate (the output device rate).
func (c *ProcessTapCapture) SampleRate() int { return c.sampleRate }

// Channels returns the tap's channel count (2 for a stereo mixdown).
func (c *ProcessTapCapture) Channels() int { return c.channels }

// Targets returns the normalised targets this capture was started with, so
// callers can rebuild the capture after an output-device change.
func (c *ProcessTapCapture) Targets() ProcessTapTargets { return c.targets }

// ReceivedSamples returns the total samples delivered by the IOProc.
func (c *ProcessTapCapture) ReceivedSamples() int64 { return c.ring.Received() }

// DroppedSamples returns the samples discarded because the ring was full.
func (c *ProcessTapCapture) DroppedSamples() int64 { return c.ring.Dropped() }

// Stop halts capture and destroys the aggregate device and tap. Idempotent.
func (c *ProcessTapCapture) Stop() error {
	if !c.stopped.CompareAndSwap(false, true) {
		return nil
	}
	return c.teardown()
}

func (c *ProcessTapCapture) teardown() error {
	processTapRegistry.Delete(c.id)

	var firstErr error
	if c.aggregate != 0 {
		if c.ioProcID != nil {
			if status := C.uxTapStopIO(c.aggregate, c.ioProcID); status != 0 && firstErr == nil {
				firstErr = fmt.Errorf("process tap IO stop failed: %s", tapStatusString(status))
			}
			c.ioProcID = nil
		}
		if status := C.uxTapDestroyAggregate(c.aggregate); status != 0 && firstErr == nil {
			firstErr = fmt.Errorf("aggregate device destroy failed: %s", tapStatusString(status))
		}
		c.aggregate = 0
	}
	if c.tap != 0 {
		if status := C.uxTapDestroy(c.tap); status != 0 && firstErr == nil {
			firstErr = fmt.Errorf("process tap destroy failed: %s", tapStatusString(status))
		}
		c.tap = 0
	}
	return firstErr
}

// PlayProcessTap starts live playback of the given processes' audio through
// the player's normal pipeline (EQ, gain, FFT, volume). The tapped processes
// are muted at source (CATapMutedWhenTapped), so only the processed output
// is audible. Stop() ends the tap and returns the player to normal use.
func (p *Player) PlayProcessTap(targets ProcessTapTargets, gainLinear float64) error {
	capture, err := StartProcessTap(targets)
	if err != nil {
		return err
	}
	if err := p.playLiveSource(capture, gainLinear); err != nil {
		capture.Stop()
		return err
	}
	return nil
}
