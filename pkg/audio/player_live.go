package audio

import (
	"errors"
	"io"
	"math"
	"strings"
	"sync/atomic"
	"time"
)

// liveTapSourceLabel is the sentinel currentPath used while playing a live
// tap source. It never resolves to a real file, so restart-from-path recovery
// is explicitly rejected instead.
const liveTapSourceLabel = "live:process-tap"

const (
	// liveReadPollInterval is how often ReadFloat32 re-checks an idle source.
	liveReadPollInterval = 5 * time.Millisecond
	// liveReadMaxWait bounds how long ReadFloat32 blocks before injecting
	// silence, keeping decoderLoop responsive to stop requests.
	liveReadMaxWait = 200 * time.Millisecond
	// liveSilenceChunkSamples is the amount of silence injected when the
	// source stays idle (e.g. the tapped process paused its audio).
	liveSilenceChunkSamples = 1024
)

// ProcessTapTargets specifies which processes a process tap should capture.
// Either bundle IDs (preferred on macOS 26+) or PIDs may be given; at least
// one valid target is required.
type ProcessTapTargets struct {
	BundleIDs []string
	PIDs      []int
}

// liveSampleSource is a pull-based, non-blocking source of interleaved
// float32 samples produced by a live capture (e.g. a Core Audio process tap).
type liveSampleSource interface {
	// ReadSamples copies up to len(dst) samples and returns the number read.
	// It never blocks.
	ReadSamples(dst []float32) int
	SampleRate() int
	Channels() int
	Stop() error
}

// normaliseTapTargets trims, deduplicates and validates tap targets while
// preserving order.
func normaliseTapTargets(targets ProcessTapTargets) (ProcessTapTargets, error) {
	var normalised ProcessTapTargets

	seenBundles := make(map[string]bool, len(targets.BundleIDs))
	for _, bundleID := range targets.BundleIDs {
		trimmed := strings.TrimSpace(bundleID)
		if trimmed == "" || seenBundles[trimmed] {
			continue
		}
		seenBundles[trimmed] = true
		normalised.BundleIDs = append(normalised.BundleIDs, trimmed)
	}

	seenPIDs := make(map[int]bool, len(targets.PIDs))
	for _, pid := range targets.PIDs {
		if pid <= 0 || seenPIDs[pid] {
			continue
		}
		seenPIDs[pid] = true
		normalised.PIDs = append(normalised.PIDs, pid)
	}

	if len(normalised.BundleIDs) == 0 && len(normalised.PIDs) == 0 {
		return ProcessTapTargets{}, errors.New("process tap targets: at least one bundle ID or PID is required")
	}
	return normalised, nil
}

// float32Decoder is an optional Decoder extension. When a decoder implements
// it, decoderLoop feeds the playback ring with float32 samples directly,
// avoiding the int16 quantisation round-trip of the byte-based Read path.
type float32Decoder interface {
	ReadFloat32(dst []float32) (int, error)
}

// liveTapDecoder adapts a liveSampleSource to the Decoder interface so the
// player's existing pipeline (ring buffer, EQ, gain, FFT) applies unchanged.
//
// Design note: the tap delivers float32 at the output device rate (48kHz),
// and the playback ring itself is float32, so this decoder keeps samples in
// float32 end to end via ReadFloat32. Converting to s16le would quantise for
// no benefit; no resampling happens because the output stream is opened at
// this decoder's sample rate.
type liveTapDecoder struct {
	source liveSampleSource
	closed atomic.Bool
}

func newLiveTapDecoder(source liveSampleSource) *liveTapDecoder {
	return &liveTapDecoder{source: source}
}

// ReadFloat32 blocks briefly until samples arrive. When the source stays
// idle past liveReadMaxWait it returns silence instead of 0 samples, because
// decoderLoop treats a zero-length read as end of track.
func (d *liveTapDecoder) ReadFloat32(dst []float32) (int, error) {
	if len(dst) == 0 {
		return 0, nil
	}
	deadline := time.Now().Add(liveReadMaxWait)
	for {
		if d.closed.Load() {
			return 0, io.EOF
		}
		if n := d.source.ReadSamples(dst); n > 0 {
			return n, nil
		}
		if time.Now().After(deadline) {
			n := liveSilenceChunkSamples
			if n > len(dst) {
				n = len(dst)
			}
			for i := 0; i < n; i++ {
				dst[i] = 0
			}
			return n, nil
		}
		time.Sleep(liveReadPollInterval)
	}
}

// Read satisfies the generic Decoder interface (s16le). The player consumes
// ReadFloat32 directly, so this path is only a compatibility fallback.
func (d *liveTapDecoder) Read(p []byte) (int, error) {
	buf := make([]float32, len(p)/2)
	n, err := d.ReadFloat32(buf)
	for i := 0; i < n; i++ {
		v := buf[i]
		if v > 1 {
			v = 1
		} else if v < -1 {
			v = -1
		}
		s := int16(v * 32767)
		p[i*2] = byte(s)
		p[i*2+1] = byte(s >> 8)
	}
	return n * 2, err
}

func (d *liveTapDecoder) SampleRate() int { return d.source.SampleRate() }
func (d *liveTapDecoder) Channels() int   { return d.source.Channels() }

// Length returns 0: a live source has no total duration, which also makes
// GetDuration report 0 without further special-casing.
func (d *liveTapDecoder) Length() int64 { return 0 }

// Seek is a harmless no-op: live sources cannot seek.
func (d *liveTapDecoder) Seek(sample int64) error { return nil }

func (d *liveTapDecoder) Close() error {
	if d.closed.CompareAndSwap(false, true) {
		return d.source.Stop()
	}
	return nil
}

// playLiveSource starts playback from a live capture source, replacing any
// current track. The output stream is opened at the source's own format
// (typically 48kHz/2ch for a process tap) so no pitch shift occurs.
func (p *Player) playLiveSource(source liveSampleSource, gainLinear float64) error {
	p.shutdownDecoderGoroutine()

	gainLinear = sanitizePlaybackGainLinear(gainLinear)
	p.baseGain.Store(math.Float64bits(gainLinear))

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stream != nil {
		p.stream.Stop()
		p.stream.Close()
		p.stream = nil
	}
	if p.file != nil {
		p.file.Close()
		p.file = nil
	}
	if p.decoder != nil {
		p.decoder.Close()
		p.decoder = nil
	}
	p.liveSource.Store(false)

	dec := newLiveTapDecoder(source)
	p.decoder = dec
	if err := p.startDecodedPlayback(liveTapSourceLabel); err != nil {
		p.decoder = nil
		dec.Close()
		return err
	}
	p.liveSource.Store(true)

	// Arm a short start-of-playback fade-in (interleaved output samples). The
	// tapped audio is muted at source until the tap is established; this
	// additionally smooths the onset of the captured stream. Set after
	// startDecodedPlayback because it resets these fields.
	fadeSamples := int64(float64(p.sampleRate)*liveStartFadeSeconds) * int64(p.channels)
	p.liveFadeTotal.Store(fadeSamples)
	p.liveFadeRemaining.Store(fadeSamples)
	return nil
}

// stopLiveSourceLocked tears down live-source state after playback stopped.
// Caller must hold p.mu.
func (p *Player) stopLiveSourceLocked() {
	if !p.liveSource.Load() {
		return
	}
	if p.decoder != nil {
		p.decoder.Close()
		p.decoder = nil
	}
	p.currentPath = ""
	p.liveSource.Store(false)
}
