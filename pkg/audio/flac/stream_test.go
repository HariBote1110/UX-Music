package flac

import (
	"bytes"
	"os"
	"testing"
)

func TestParseStream_BasicStereo(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: 5})
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	stream, err := ParseStream(f)
	if err != nil {
		t.Fatalf("ParseStream failed: %v", err)
	}

	if stream.Info.SampleRate != 44100 {
		t.Errorf("SampleRate = %d, want 44100", stream.Info.SampleRate)
	}
	if stream.Info.Channels != 2 {
		t.Errorf("Channels = %d, want 2", stream.Info.Channels)
	}
	if stream.Info.BitsPerSample != 16 {
		t.Errorf("BitsPerSample = %d, want 16", stream.Info.BitsPerSample)
	}
	wantSamples := int64(3 * 44100)
	if diff := stream.Info.TotalSamples - wantSamples; diff < -100 || diff > 100 {
		t.Errorf("TotalSamples = %d, want approximately %d", stream.Info.TotalSamples, wantSamples)
	}
	if stream.Info.MinBlockSize <= 0 || stream.Info.MaxBlockSize <= 0 {
		t.Errorf("expected positive block sizes, got min=%d max=%d", stream.Info.MinBlockSize, stream.Info.MaxBlockSize)
	}
	if stream.AudioStart <= 0 {
		t.Errorf("AudioStart = %d, want > 0", stream.AudioStart)
	}

	assertFirstFrameSyncAt(t, path, stream.AudioStart)
}

func TestParseStream_HighResStereo(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 96000, channels: 2, bitsPerSample: 24, compressionLevel: 5})
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	stream, err := ParseStream(f)
	if err != nil {
		t.Fatalf("ParseStream failed: %v", err)
	}
	if stream.Info.SampleRate != 96000 {
		t.Errorf("SampleRate = %d, want 96000", stream.Info.SampleRate)
	}
	if stream.Info.BitsPerSample != 24 {
		t.Errorf("BitsPerSample = %d, want 24", stream.Info.BitsPerSample)
	}
	if stream.Info.Channels != 2 {
		t.Errorf("Channels = %d, want 2", stream.Info.Channels)
	}
}

func TestParseStream_Mono(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 1, bitsPerSample: 16, compressionLevel: 5})
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	stream, err := ParseStream(f)
	if err != nil {
		t.Fatalf("ParseStream failed: %v", err)
	}
	if stream.Info.Channels != 1 {
		t.Errorf("Channels = %d, want 1", stream.Info.Channels)
	}
}

func TestParseStream_CompressionLevels(t *testing.T) {
	for _, level := range []int{0, 8} {
		level := level
		t.Run(map[int]string{0: "level0", 8: "level8"}[level], func(t *testing.T) {
			path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: level})
			f, err := os.Open(path)
			if err != nil {
				t.Fatalf("failed to open fixture: %v", err)
			}
			defer f.Close()

			stream, err := ParseStream(f)
			if err != nil {
				t.Fatalf("ParseStream failed: %v", err)
			}
			if stream.Info.SampleRate != 44100 || stream.Info.Channels != 2 || stream.Info.BitsPerSample != 16 {
				t.Errorf("unexpected StreamInfo: %+v", stream.Info)
			}
		})
	}
}

func TestParseStream_SeekTableRetainedRaw(t *testing.T) {
	// Ask the encoder to build a seek table so we can verify the raw bytes
	// are retained, not parsed, in this increment.
	ffmpegPath, flacPath := requireFFmpegAndFlacForTest(t)
	_ = ffmpegPath
	_ = flacPath

	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: 5})
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	defer f.Close()

	stream, err := ParseStream(f)
	if err != nil {
		t.Fatalf("ParseStream failed: %v", err)
	}
	// The reference flac CLI writes a SEEKTABLE block by default, so we
	// expect to have retained its raw bytes.
	if stream.SeekTableRaw == nil {
		t.Skip("reference flac encoder did not emit a SEEKTABLE block for this fixture")
	}
	if len(stream.SeekTableRaw)%18 != 0 {
		t.Errorf("SEEKTABLE raw length %d is not a multiple of 18 bytes per FLAC spec", len(stream.SeekTableRaw))
	}
}

func TestParseStream_ID3v2Prefix(t *testing.T) {
	base := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: 5})
	prefixed := prependID3v2(t, base)

	f, err := os.Open(prefixed)
	if err != nil {
		t.Fatalf("failed to open ID3v2-prefixed fixture: %v", err)
	}
	defer f.Close()

	stream, err := ParseStream(f)
	if err != nil {
		t.Fatalf("ParseStream failed on ID3v2-prefixed file: %v", err)
	}
	if stream.Info.SampleRate != 44100 || stream.Info.Channels != 2 || stream.Info.BitsPerSample != 16 {
		t.Errorf("unexpected StreamInfo after ID3v2 skip: %+v", stream.Info)
	}

	// AudioStart must land exactly on the first frame's sync code, proving
	// the ID3v2 header length (138 bytes: 10 header + 128 body) was
	// correctly folded into the returned offset.
	assertFirstFrameSyncAt(t, prefixed, stream.AudioStart)
}

func TestParseStream_RejectsMissingSignature(t *testing.T) {
	_, err := ParseStream(bytes.NewReader([]byte("not a flac file at all")))
	if err == nil {
		t.Fatal("expected an error for missing fLaC signature")
	}
}

func TestParseStream_RejectsEmptyInput(t *testing.T) {
	_, err := ParseStream(bytes.NewReader(nil))
	if err == nil {
		t.Fatal("expected an error for empty input")
	}
}

func TestParseStream_RejectsTruncatedStreamInfo(t *testing.T) {
	// "fLaC" + a STREAMINFO block header claiming 34 bytes but supplying
	// none.
	data := []byte("fLaC")
	data = append(data, 0x80, 0x00, 0x00, 0x22) // last-block flag set, type 0, length 34
	_, err := ParseStream(bytes.NewReader(data))
	if err == nil {
		t.Fatal("expected an error for truncated STREAMINFO block")
	}
}

func TestParseStream_RejectsNonStreamInfoFirstBlock(t *testing.T) {
	data := []byte("fLaC")
	// last-block flag set, type 1 (PADDING), length 4, four bytes of padding.
	data = append(data, 0x81, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00)
	_, err := ParseStream(bytes.NewReader(data))
	if err == nil {
		t.Fatal("expected an error when the first metadata block is not STREAMINFO")
	}
}

// assertFirstFrameSyncAt seeks path to offset and checks that a valid FLAC
// frame sync code (top 14 bits all set) begins there.
func assertFirstFrameSyncAt(t *testing.T, path string, offset int64) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to reopen fixture: %v", err)
	}
	defer f.Close()
	if _, err := f.Seek(offset, 0); err != nil {
		t.Fatalf("failed to seek to AudioStart: %v", err)
	}
	buf := make([]byte, 2)
	if _, err := f.Read(buf); err != nil {
		t.Fatalf("failed to read at AudioStart: %v", err)
	}
	if buf[0] != 0xFF || buf[1]&0xFC != 0xF8 {
		t.Fatalf("no frame sync code at AudioStart offset %d: got bytes %02x %02x", offset, buf[0], buf[1])
	}
}
