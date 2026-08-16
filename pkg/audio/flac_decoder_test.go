// Tests for flacAdapterDecoder, the pkg/audio/flac-backed implementation of
// the Decoder interface (see player.go:241) that replaces the
// mewkiz/flac-based flacDecoder.
package audio

import (
	"errors"
	"io"
	"os"
	"testing"

	nativeflac "ux-music-sidecar/pkg/audio/flac"
)

// decodeAllViaNativeDecoder decodes flacPath directly with the low-level
// pkg/audio/flac decoder, returning per-channel raw int32 samples. Used as
// the independent reference for adapter fidelity tests.
func decodeAllViaNativeDecoder(t *testing.T, flacPath string) ([][]int32, nativeflac.StreamInfo) {
	t.Helper()
	f, err := os.Open(flacPath)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	dec, err := nativeflac.NewDecoder(f)
	if err != nil {
		t.Fatalf("nativeflac.NewDecoder failed: %v", err)
	}
	defer dec.Close()

	info := dec.Info()
	out := make([][]int32, info.Channels)
	for {
		frame, err := dec.ReadFrame()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("ReadFrame failed: %v", err)
		}
		for ch := 0; ch < info.Channels; ch++ {
			out[ch] = append(out[ch], frame.Samples[ch]...)
		}
	}
	return out, info
}

func TestFlacAdapterDecoder_ReadFloat32_24bitFidelitySurvives(t *testing.T) {
	path := generateAudioFlacFixture(t, 96000, 2, 24, 1)

	rawChannels, info := decodeAllViaNativeDecoder(t, path)

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer file.Close()

	dec, err := newFLACAdapterDecoder(file)
	if err != nil {
		t.Fatalf("newFLACAdapterDecoder failed: %v", err)
	}
	defer dec.Close()

	scale := float32(int64(1) << uint(info.BitsPerSample-1))

	buf := make([]float32, dec.Channels()*2048)
	var got []float32
	for {
		n, err := dec.ReadFloat32(buf)
		got = append(got, buf[:n]...)
		if errors.Is(err, io.EOF) || n == 0 {
			break
		}
		if err != nil {
			t.Fatalf("ReadFloat32 failed: %v", err)
		}
	}

	frameCount := len(rawChannels[0])
	if len(got) != frameCount*info.Channels {
		t.Fatalf("got %d float32 samples, want %d (frames %d x channels %d)", len(got), frameCount*info.Channels, frameCount, info.Channels)
	}

	// A discriminating check: verify at least one sample carries information
	// below the top 8 bits (i.e. genuinely uses 24-bit resolution), so this
	// test cannot pass under the old >>(bps-16) truncation.
	foundLowBitInformation := false

	for i := 0; i < frameCount; i++ {
		for ch := 0; ch < info.Channels; ch++ {
			raw := rawChannels[ch][i]
			want := float32(raw) / scale
			if want > 1 {
				want = 1
			} else if want < -1 {
				want = -1
			}
			gotSample := got[i*info.Channels+ch]
			diff := gotSample - want
			if diff < 0 {
				diff = -diff
			}
			if diff > 1e-6 {
				t.Fatalf("sample %d channel %d: got %v, want %v (raw=%d)", i, ch, gotSample, want, raw)
			}
			if raw&0xFF != 0 {
				foundLowBitInformation = true
			}
		}
	}

	if !foundLowBitInformation {
		t.Fatal("fixture unexpectedly carries no low-8-bit information; test cannot discriminate truncation")
	}
}

func TestFlacAdapterDecoder_Read_Int16LittleEndian(t *testing.T) {
	path := generateAudioFlacFixture(t, 44100, 2, 16, 1)

	rawChannels, info := decodeAllViaNativeDecoder(t, path)

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer file.Close()

	dec, err := newFLACAdapterDecoder(file)
	if err != nil {
		t.Fatalf("newFLACAdapterDecoder failed: %v", err)
	}
	defer dec.Close()

	buf := make([]byte, dec.Channels()*2*2048)
	var got []byte
	for {
		n, err := dec.Read(buf)
		got = append(got, buf[:n]...)
		if errors.Is(err, io.EOF) || n == 0 {
			break
		}
		if err != nil {
			t.Fatalf("Read failed: %v", err)
		}
	}

	frameCount := len(rawChannels[0])
	if len(got) != frameCount*info.Channels*2 {
		t.Fatalf("got %d bytes, want %d", len(got), frameCount*info.Channels*2)
	}

	for i := 0; i < frameCount; i++ {
		for ch := 0; ch < info.Channels; ch++ {
			want := int16(rawChannels[ch][i])
			off := (i*info.Channels + ch) * 2
			gotSample := int16(uint16(got[off]) | uint16(got[off+1])<<8)
			if gotSample != want {
				t.Fatalf("sample %d channel %d: got %d, want %d", i, ch, gotSample, want)
			}
		}
	}
}

func TestFlacAdapterDecoder_Seek_MatchesLinearDecode(t *testing.T) {
	path := generateAudioFlacFixture(t, 44100, 2, 16, 2)

	rawChannels, info := decodeAllViaNativeDecoder(t, path)
	const target = int64(50000)
	if int64(len(rawChannels[0])) <= target {
		t.Fatalf("fixture too short (%d samples) for target %d", len(rawChannels[0]), target)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer file.Close()

	dec, err := newFLACAdapterDecoder(file)
	if err != nil {
		t.Fatalf("newFLACAdapterDecoder failed: %v", err)
	}
	defer dec.Close()

	if err := dec.Seek(target); err != nil {
		t.Fatalf("Seek failed: %v", err)
	}

	buf := make([]float32, dec.Channels()*2048)
	var got []float32
	for {
		n, err := dec.ReadFloat32(buf)
		got = append(got, buf[:n]...)
		if errors.Is(err, io.EOF) || n == 0 {
			break
		}
		if err != nil {
			t.Fatalf("ReadFloat32 after seek failed: %v", err)
		}
	}

	scale := float32(int64(1) << uint(info.BitsPerSample-1))
	wantFrames := len(rawChannels[0]) - int(target)
	if len(got) != wantFrames*info.Channels {
		t.Fatalf("got %d float32 samples after seek, want %d", len(got), wantFrames*info.Channels)
	}

	for i := 0; i < wantFrames; i++ {
		for ch := 0; ch < info.Channels; ch++ {
			raw := rawChannels[ch][int(target)+i]
			want := float32(raw) / scale
			gotSample := got[i*info.Channels+ch]
			diff := gotSample - want
			if diff < 0 {
				diff = -diff
			}
			if diff > 1e-6 {
				t.Fatalf("post-seek sample %d channel %d: got %v, want %v", i, ch, gotSample, want)
			}
		}
	}
}
