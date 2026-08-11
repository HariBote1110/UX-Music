package server

import (
	"testing"
	"time"
)

// fakeTapCapture is a minimal audio.TapCapture stand-in that lets tests
// drive processTapRelaySource without Core Audio hardware.
type fakeTapCapture struct {
	samples    []float32
	sampleRate int
	channels   int
	stopped    bool
}

func (f *fakeTapCapture) ReadSamples(dst []float32) int {
	if len(f.samples) == 0 {
		return 0
	}
	n := copy(dst, f.samples)
	f.samples = f.samples[n:]
	return n
}

func (f *fakeTapCapture) SampleRate() int { return f.sampleRate }
func (f *fakeTapCapture) Channels() int   { return f.channels }
func (f *fakeTapCapture) Stop() error {
	f.stopped = true
	return nil
}

func TestProcessTapRelaySource_ReadPCMDeliversQueuedSamplesAndFormat(t *testing.T) {
	fake := &fakeTapCapture{samples: []float32{0.1, 0.2, 0.3, 0.4}, sampleRate: 48000, channels: 2}
	source := newProcessTapRelaySource(fake)

	if got := source.SampleRate(); got != 48000 {
		t.Fatalf("SampleRate() = %d, want 48000", got)
	}
	if got := source.Channels(); got != 2 {
		t.Fatalf("Channels() = %d, want 2", got)
	}

	dst := make([]float32, 4)
	n, ok := source.ReadPCM(dst)
	if !ok {
		t.Fatalf("ReadPCM() ok = false, want true")
	}
	if n != 4 {
		t.Fatalf("ReadPCM() n = %d, want 4", n)
	}
	if dst[0] != 0.1 || dst[3] != 0.4 {
		t.Fatalf("ReadPCM() dst = %v, want the queued samples", dst)
	}
}

func TestProcessTapRelaySource_ReadPCMReturnsOKWithZeroWhenTapEmpty(t *testing.T) {
	fake := &fakeTapCapture{sampleRate: 48000, channels: 2}
	source := newProcessTapRelaySource(fake)

	dst := make([]float32, 4)
	n, ok := source.ReadPCM(dst)
	if !ok {
		t.Fatalf("ReadPCM() ok = false, want true (tap being momentarily empty is not exhaustion)")
	}
	if n != 0 {
		t.Fatalf("ReadPCM() n = %d, want 0", n)
	}
}

func TestProcessTapRelaySource_CloseStopsFurtherReadsAndReturnsNotOK(t *testing.T) {
	fake := &fakeTapCapture{samples: []float32{1, 2, 3}, sampleRate: 48000, channels: 2}
	source := newProcessTapRelaySource(fake)

	source.Close()

	dst := make([]float32, 4)
	n, ok := source.ReadPCM(dst)
	if ok {
		t.Fatalf("ReadPCM() ok = true after Close(), want false")
	}
	if n != 0 {
		t.Fatalf("ReadPCM() n = %d after Close(), want 0", n)
	}
	// Close() must not itself stop the underlying capture — that remains
	// the caller's responsibility (see NotifyYouTubePlaybackState), because
	// the relay engine's own pumpPCM goroutine may still be mid-read when
	// Close() is called from another goroutine.
	if fake.stopped {
		t.Fatalf("underlying capture Stop() was called by source.Close(), want it left to the caller")
	}
}

func TestProcessTapRelaySource_PollIntervalSleepsBrieflyOnEmptyRead(t *testing.T) {
	fake := &fakeTapCapture{sampleRate: 48000, channels: 2}
	source := newProcessTapRelaySource(fake)

	start := time.Now()
	source.ReadPCM(make([]float32, 4))
	elapsed := time.Since(start)

	if elapsed < relayTapPollInterval {
		t.Fatalf("ReadPCM() returned after %v on empty read, want at least the poll interval %v (busy-loop risk, see progress/remote-relay.md 未確定 item 3)", elapsed, relayTapPollInterval)
	}
}
