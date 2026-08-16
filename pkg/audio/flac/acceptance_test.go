// This file contains the decisive acceptance tests for the decoder: bit
// exactness against the reference `flac` CLI decoder, and independent
// STREAMINFO MD5 self-verification, across a matrix of fixtures. It also
// covers malformed input (truncation, byte corruption) to confirm the
// decoder never panics and always reports an error.
package flac

import (
	"bytes"
	"crypto/md5"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"testing"
)

// decodeReferenceWAV runs `flac -d` on flacPath and returns the raw PCM
// payload of the resulting WAV's "data" chunk, plus the chunk's declared
// bits-per-sample and channel count, read straight from the WAV header so
// the comparison doesn't depend on any assumptions about ffmpeg/flac
// defaults.
func decodeReferenceWAV(t *testing.T, flacPath string) (pcm []byte, channels int, bitsPerSample int) {
	t.Helper()
	_, flacCLI := requireFFmpegAndFlacForTest(t)

	wavPath := flacPath + ".ref.wav"
	cmd := exec.Command(flacCLI, "-f", "--totally-silent", "-d", "-o", wavPath, flacPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("reference flac -d failed: %v\n%s", err, out)
	}
	defer os.Remove(wavPath)

	data, err := os.ReadFile(wavPath)
	if err != nil {
		t.Fatalf("failed to read reference WAV: %v", err)
	}
	return parseWAV(t, data)
}

// parseWAV extracts the PCM payload and format fields from a canonical
// little-endian WAV file, walking its RIFF chunks rather than assuming a
// fixed header layout.
func parseWAV(t *testing.T, data []byte) (pcm []byte, channels int, bitsPerSample int) {
	t.Helper()
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		t.Fatalf("not a RIFF/WAVE file")
	}
	pos := 12
	for pos+8 <= len(data) {
		id := string(data[pos : pos+4])
		size := int(binary.LittleEndian.Uint32(data[pos+4 : pos+8]))
		body := pos + 8
		if body+size > len(data) {
			t.Fatalf("WAV chunk %q overruns file (size %d at offset %d)", id, size, body)
		}
		switch id {
		case "fmt ":
			if size < 16 {
				t.Fatalf("fmt chunk too small: %d", size)
			}
			channels = int(binary.LittleEndian.Uint16(data[body+2 : body+4]))
			bitsPerSample = int(binary.LittleEndian.Uint16(data[body+14 : body+16]))
		case "data":
			pcm = data[body : body+size]
		}
		pos = body + size
		if size%2 == 1 {
			pos++ // chunks are word-aligned
		}
	}
	if pcm == nil {
		t.Fatalf("WAV file has no data chunk")
	}
	if channels == 0 || bitsPerSample == 0 {
		t.Fatalf("WAV file has no fmt chunk (or it precedes data unexpectedly)")
	}
	return pcm, channels, bitsPerSample
}

// wavSampleAt returns PCM sample [frame][channel] from an interleaved,
// little-endian WAV data chunk as a sign-extended int32.
func wavSampleAt(pcm []byte, channels, bitsPerSample, frame, channel int) int32 {
	bytesPerSample := bitsPerSample / 8
	frameSize := bytesPerSample * channels
	off := frame*frameSize + channel*bytesPerSample
	switch bytesPerSample {
	case 2:
		return int32(int16(binary.LittleEndian.Uint16(pcm[off : off+2])))
	case 3:
		b0, b1, b2 := pcm[off], pcm[off+1], pcm[off+2]
		v := int32(b0) | int32(b1)<<8 | int32(b2)<<16
		if v&0x800000 != 0 {
			v |= ^int32(0xFFFFFF)
		}
		return v
	default:
		panic(fmt.Sprintf("unsupported WAV sample width %d bytes", bytesPerSample))
	}
}

// decodeAllOurs decodes flacPath completely with our Decoder and returns
// the per-channel sample streams (concatenated across all frames) plus the
// stream's StreamInfo.
func decodeAllOurs(t *testing.T, flacPath string) ([][]int32, StreamInfo) {
	t.Helper()
	f, err := os.Open(flacPath)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	dec, err := NewDecoder(f)
	if err != nil {
		t.Fatalf("NewDecoder failed: %v", err)
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

// assertBitExact compares our decoded channels against the reference WAV's
// PCM payload, sample for sample, reporting the first mismatch.
func assertBitExact(t *testing.T, ours [][]int32, info StreamInfo, refPCM []byte, refChannels, refBits int) {
	t.Helper()
	if refChannels != info.Channels {
		t.Fatalf("reference decoder reports %d channels, our StreamInfo reports %d", refChannels, info.Channels)
	}
	if refBits != info.BitsPerSample {
		t.Fatalf("reference decoder reports %d bits/sample, our StreamInfo reports %d", refBits, info.BitsPerSample)
	}

	bytesPerSample := refBits / 8
	frameCount := len(refPCM) / (bytesPerSample * refChannels)

	for ch := 0; ch < info.Channels; ch++ {
		if len(ours[ch]) != frameCount {
			t.Fatalf("channel %d: decoded %d samples, reference has %d", ch, len(ours[ch]), frameCount)
		}
	}

	for i := 0; i < frameCount; i++ {
		for ch := 0; ch < info.Channels; ch++ {
			want := wavSampleAt(refPCM, refChannels, refBits, i, ch)
			got := ours[ch][i]
			if got != want {
				t.Fatalf("first mismatch at sample %d, channel %d: got %d, want %d (reference)", i, ch, got, want)
			}
		}
	}
}

// flacStreamMD5 computes the MD5 of decoded PCM exactly as RFC 9639 defines
// it for STREAMINFO: little-endian, channel-interleaved, using the minimum
// whole number of bytes that can hold bitsPerSample.
func flacStreamMD5(channels [][]int32, bitsPerSample int) [16]byte {
	bytesPerSample := (bitsPerSample + 7) / 8
	if len(channels) == 0 {
		h := md5.Sum(nil)
		return h
	}
	frameCount := len(channels[0])

	h := md5.New()
	buf := make([]byte, bytesPerSample)
	for i := 0; i < frameCount; i++ {
		for _, ch := range channels {
			v := uint32(ch[i])
			for b := 0; b < bytesPerSample; b++ {
				buf[b] = byte(v >> (8 * uint(b)))
			}
			h.Write(buf)
		}
	}
	var sum [16]byte
	copy(sum[:], h.Sum(nil))
	return sum
}

func runBitExactnessAndMD5(t *testing.T, flacPath string) {
	t.Helper()
	ours, info := decodeAllOurs(t, flacPath)

	gotMD5 := flacStreamMD5(ours, info.BitsPerSample)
	if gotMD5 != info.MD5 {
		t.Errorf("decoded PCM MD5 %x does not match STREAMINFO MD5 %x", gotMD5, info.MD5)
	}

	refPCM, refChannels, refBits := decodeReferenceWAV(t, flacPath)
	assertBitExact(t, ours, info, refPCM, refChannels, refBits)
}

func TestAcceptance_BitExactnessAndMD5(t *testing.T) {
	matrix := []struct {
		name string
		p    fixtureParams
	}{
		{"44.1kHz_16bit_stereo_c0", fixtureParams{44100, 2, 16, 0, 2}},
		{"44.1kHz_16bit_stereo_c5", fixtureParams{44100, 2, 16, 5, 2}},
		{"44.1kHz_16bit_stereo_c8", fixtureParams{44100, 2, 16, 8, 2}},
		{"96kHz_24bit_stereo_c5", fixtureParams{96000, 2, 24, 5, 2}},
		{"96kHz_24bit_stereo_c8", fixtureParams{96000, 2, 24, 8, 2}},
		{"44.1kHz_16bit_mono_c5", fixtureParams{44100, 1, 16, 5, 2}},
		{"44.1kHz_16bit_mono_c0", fixtureParams{44100, 1, 16, 0, 2}},
	}

	for _, tc := range matrix {
		t.Run(tc.name, func(t *testing.T) {
			path := generateFixture(t, tc.p)
			runBitExactnessAndMD5(t, path)
		})
	}

	t.Run("mid_side_forced", func(t *testing.T) {
		p := fixtureParams{44100, 2, 16, 5, 2}
		path := generateFixtureWithFlacArgs(t, p, []string{"-m"}, "_midside")
		runBitExactnessAndMD5(t, path)
	})

	t.Run("very_short_file_under_one_block", func(t *testing.T) {
		// Default block sizes at these compression levels are in the
		// thousands of samples; a fixture of a few hundred samples forces
		// a single, partial final frame.
		shortPath := generateShortFixture(t, 44100, 2, 16, 300)
		runBitExactnessAndMD5(t, shortPath)
	})
}

// generateShortFixture builds a FLAC fixture with an exact, short sample
// count (well under a typical block size) so the acceptance test exercises
// a stream consisting of a single partial final frame.
func generateShortFixture(t *testing.T, sampleRate, channels, bitsPerSample, samples int) string {
	t.Helper()
	ffmpegPath, flacPath := requireFFmpegAndFlacForTest(t)

	fixtureMu.Lock()
	defer fixtureMu.Unlock()
	strKey := fmt.Sprintf("short_%dhz_%dch_%dbit_%dsamples", sampleRate, channels, bitsPerSample, samples)
	if path, ok := fixtureCacheByKey[strKey]; ok {
		return path
	}

	wavPath := fixtureDir + "/" + strKey + ".wav"
	flacOutPath := fixtureDir + "/" + strKey + ".flac"

	durationSeconds := float64(samples) / float64(sampleRate)
	filter := fmt.Sprintf("sine=frequency=440:duration=%f", durationSeconds)
	ffmpegArgs := []string{
		"-y", "-hide_banner", "-loglevel", "error",
		"-filter_complex", filter,
		"-ar", fmt.Sprintf("%d", sampleRate),
		"-ac", fmt.Sprintf("%d", channels),
		"-c:a", "pcm_s16le",
		wavPath,
	}
	cmd := exec.Command(ffmpegPath, ffmpegArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg short fixture generation failed: %v\n%s", err, out)
	}

	cmd = exec.Command(flacPath, "-f", "--totally-silent", "-5", "-o", flacOutPath, wavPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("flac encode of short fixture failed: %v\n%s", err, out)
	}

	fixtureCacheByKey[strKey] = flacOutPath
	return flacOutPath
}

// TestAcceptance_MalformedInput asserts the decoder returns an error
// (never panics) on truncated and byte-corrupted FLAC data.
func TestAcceptance_MalformedInput(t *testing.T) {
	p := fixtureParams{44100, 2, 16, 5, 1}
	path := generateFixture(t, p)
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read fixture: %v", err)
	}

	stream, err := ParseStream(bytes.NewReader(original))
	if err != nil {
		t.Fatalf("failed to parse fixture stream header: %v", err)
	}

	t.Run("truncated mid-frame", func(t *testing.T) {
		// Cut off partway through the audio data, well past the first
		// frame's start but before the stream's natural end.
		cut := int(stream.AudioStart) + (len(original)-int(stream.AudioStart))/2
		truncated := original[:cut]
		decodeExpectingError(t, truncated)
	})

	t.Run("flipped bytes inside frame body", func(t *testing.T) {
		corrupted := append([]byte(nil), original...)
		// Flip a handful of bytes well inside the audio data, away from
		// the stream header, to corrupt frame contents without necessarily
		// destroying frame sync.
		for _, off := range []int{20, 100, 250} {
			idx := int(stream.AudioStart) + off
			if idx < len(corrupted) {
				corrupted[idx] ^= 0xFF
			}
		}
		decodeExpectingError(t, corrupted)
	})
}

// decodeExpectingError fully decodes data with our Decoder, asserting that
// it never panics and that it reports an error somewhere before or at
// EOF (a clean io.EOF with no error anywhere is a test failure, since the
// input was deliberately corrupted).
func decodeExpectingError(t *testing.T, data []byte) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("decoder panicked on malformed input: %v", r)
		}
	}()

	dec, err := NewDecoder(bytes.NewReader(data))
	if err != nil {
		// Failing during stream header parsing is a valid way to reject
		// malformed input.
		return
	}
	defer dec.Close()

	for {
		_, err := dec.ReadFrame()
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			t.Fatal("expected an error decoding malformed input, got a clean io.EOF")
		}
		return // any other error is the expected outcome
	}
}
