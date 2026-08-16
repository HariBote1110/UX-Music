// This file adapts pkg/audio/flac, the hand-written FLAC decoder, to this
// package's Decoder interface (player.go:241), replacing the
// mewkiz/flac-based flacDecoder entirely.
package audio

import (
	"fmt"
	"os"

	nativeflac "ux-music-sidecar/pkg/audio/flac"
)

// flacAdapterDecoder wraps a pkg/audio/flac.Decoder. It implements both the
// byte-oriented Decoder interface (Read: int16 little-endian interleaved,
// kept for compatibility) and ReadFloat32 (the float32Decoder optional
// interface, see player_live.go:80), which decoderLoop prefers whenever a
// decoder implements it. Both read paths pull samples from the same
// underlying frame via fillFrame, so they cannot diverge, and ReadFloat32
// scales by the stream's actual bit depth rather than a hardcoded one,
// removing the previous 24-bit truncation.
type flacAdapterDecoder struct {
	file *os.File
	dec  *nativeflac.Decoder

	sampleRate    int
	channels      int
	bitsPerSample int
	length        int64

	frame    *nativeflac.Frame
	framePos int
}

// newFLACDecoder is player.go's entry point for FLAC playback: it
// constructs the native pkg/audio/flac-backed adapter, replacing the
// mewkiz/flac-based flacDecoder. On open failure, player.go falls back to
// the ffmpeg decoder (see startDecodedPlayback's ".flac" case); this
// decoder itself never falls back mid-stream, since pkg/audio/flac reports
// errors rather than panicking on malformed input.
func newFLACDecoder(file *os.File) (*flacAdapterDecoder, error) {
	return newFLACAdapterDecoder(file)
}

// newFLACAdapterDecoder opens file as a FLAC stream via the native decoder.
func newFLACAdapterDecoder(file *os.File) (*flacAdapterDecoder, error) {
	dec, err := nativeflac.NewDecoder(file)
	if err != nil {
		return nil, err
	}
	info := dec.Info()
	return &flacAdapterDecoder{
		file:          file,
		dec:           dec,
		sampleRate:    info.SampleRate,
		channels:      info.Channels,
		bitsPerSample: info.BitsPerSample,
		length:        info.TotalSamples,
	}, nil
}

// fillFrame ensures d.frame holds unread samples, decoding the next frame
// if the current one (if any) is exhausted. It leaves d.frame/d.framePos
// untouched, and returns nil, when samples remain.
func (d *flacAdapterDecoder) fillFrame() error {
	if d.frame != nil && d.framePos < d.frame.BlockSize {
		return nil
	}
	frame, err := d.dec.ReadFrame()
	if err != nil {
		return err
	}
	d.frame = frame
	d.framePos = 0
	return nil
}

// ReadFloat32 implements float32Decoder: it fills dst with interleaved
// float32 samples, scaled by dividing by 1<<(bitsPerSample-1) — the shift is
// derived from the stream's actual bit depth, never hardcoded — and clamped
// to [-1, 1].
func (d *flacAdapterDecoder) ReadFloat32(dst []float32) (int, error) {
	if len(dst) == 0 || d.channels == 0 {
		return 0, nil
	}
	scale := float32(int64(1) << uint(d.bitsPerSample-1))

	written := 0
	for written+d.channels <= len(dst) {
		if err := d.fillFrame(); err != nil {
			if written > 0 {
				return written, nil
			}
			return 0, err
		}
		for ch := 0; ch < d.channels; ch++ {
			v := float32(d.frame.Samples[ch][d.framePos]) / scale
			if v > 1 {
				v = 1
			} else if v < -1 {
				v = -1
			}
			dst[written] = v
			written++
		}
		d.framePos++
	}
	return written, nil
}

// Read implements the generic Decoder interface: int16 little-endian,
// channel-interleaved, for callers that do not use ReadFloat32.
func (d *flacAdapterDecoder) Read(p []byte) (int, error) {
	sampleBytes := d.channels * 2
	if sampleBytes == 0 || len(p) < sampleBytes {
		return 0, nil
	}
	shift := d.bitsPerSample - 16

	written := 0
	for written+sampleBytes <= len(p) {
		if err := d.fillFrame(); err != nil {
			if written > 0 {
				return written, nil
			}
			return 0, err
		}
		for ch := 0; ch < d.channels; ch++ {
			sample := d.frame.Samples[ch][d.framePos]
			var s16 int16
			switch {
			case shift > 0:
				s16 = int16(sample >> uint(shift))
			case shift < 0:
				s16 = int16(sample << uint(-shift))
			default:
				s16 = int16(sample)
			}
			p[written] = byte(s16)
			p[written+1] = byte(s16 >> 8)
			written += 2
		}
		d.framePos++
	}
	return written, nil
}

func (d *flacAdapterDecoder) SampleRate() int {
	return d.sampleRate
}

func (d *flacAdapterDecoder) Channels() int {
	return d.channels
}

func (d *flacAdapterDecoder) Length() int64 {
	return d.length
}

// Seek repositions to sample, clamping out-of-range requests rather than
// erroring (matching the other Decoder implementations' Seek conventions,
// e.g. wavDecoder.Seek).
func (d *flacAdapterDecoder) Seek(sample int64) error {
	if sample < 0 {
		sample = 0
	}
	if d.length > 0 && sample > d.length {
		sample = d.length
	}
	if err := d.dec.SeekSample(sample); err != nil {
		return fmt.Errorf("flac: seek failed: %w", err)
	}
	d.frame = nil
	d.framePos = 0
	return nil
}

func (d *flacAdapterDecoder) Close() error {
	return d.dec.Close()
}
