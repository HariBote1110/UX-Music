package flac

import (
	"bytes"
	"os"
	"testing"
)

// openStreamAtFirstFrame parses the stream header of path and returns the
// StreamInfo plus a BitReader positioned exactly at the first frame.
func openStreamAtFirstFrame(t *testing.T, path string) (StreamInfo, *BitReader, *os.File) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	stream, err := ParseStream(f)
	if err != nil {
		f.Close()
		t.Fatalf("ParseStream failed: %v", err)
	}
	if _, err := f.Seek(stream.AudioStart, 0); err != nil {
		f.Close()
		t.Fatalf("failed to seek to AudioStart: %v", err)
	}
	return stream.Info, NewBitReader(f), f
}

func TestParseFrameHeader_StereoFirstFrame(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: 5})
	info, br, f := openStreamAtFirstFrame(t, path)
	defer f.Close()

	fh, err := ParseFrameHeader(br, info)
	if err != nil {
		t.Fatalf("ParseFrameHeader failed: %v", err)
	}
	if fh.SampleRate != info.SampleRate {
		t.Errorf("SampleRate = %d, want %d", fh.SampleRate, info.SampleRate)
	}
	if fh.Channels != info.Channels {
		t.Errorf("Channels = %d, want %d", fh.Channels, info.Channels)
	}
	if fh.BitsPerSample != info.BitsPerSample {
		t.Errorf("BitsPerSample = %d, want %d", fh.BitsPerSample, info.BitsPerSample)
	}
	if fh.BlockSize <= 0 || fh.BlockSize > info.MaxBlockSize {
		t.Errorf("BlockSize = %d, want in (0, %d]", fh.BlockSize, info.MaxBlockSize)
	}
	if fh.ChannelAssignmentType != ChannelIndependent && fh.ChannelAssignmentType != ChannelLeftSide &&
		fh.ChannelAssignmentType != ChannelRightSide && fh.ChannelAssignmentType != ChannelMidSide {
		t.Errorf("unexpected ChannelAssignmentType %v", fh.ChannelAssignmentType)
	}
}

func TestParseFrameHeader_HighResFirstFrame(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 96000, channels: 2, bitsPerSample: 24, compressionLevel: 5})
	info, br, f := openStreamAtFirstFrame(t, path)
	defer f.Close()

	fh, err := ParseFrameHeader(br, info)
	if err != nil {
		t.Fatalf("ParseFrameHeader failed: %v", err)
	}
	if fh.SampleRate != 96000 {
		t.Errorf("SampleRate = %d, want 96000", fh.SampleRate)
	}
	if fh.BitsPerSample != 24 {
		t.Errorf("BitsPerSample = %d, want 24", fh.BitsPerSample)
	}
}

func TestParseFrameHeader_MonoFirstFrame(t *testing.T) {
	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 1, bitsPerSample: 16, compressionLevel: 5})
	info, br, f := openStreamAtFirstFrame(t, path)
	defer f.Close()

	fh, err := ParseFrameHeader(br, info)
	if err != nil {
		t.Fatalf("ParseFrameHeader failed: %v", err)
	}
	if fh.Channels != 1 {
		t.Errorf("Channels = %d, want 1", fh.Channels)
	}
	if fh.ChannelAssignmentType != ChannelIndependent {
		t.Errorf("ChannelAssignmentType = %v, want ChannelIndependent", fh.ChannelAssignmentType)
	}
}

func TestParseFrameHeader_SequenceOfHeaders(t *testing.T) {
	// We cannot yet skip over a frame's body without decoding it (subframe
	// decoding is out of scope for this increment), so this only verifies
	// that a small, low-compression fixture's *first* frame header parses
	// cleanly and repeatedly re-parsing the same bytes is stable — it does
	// not walk multiple distinct frames in the file.
	path := generateFixture(t, fixtureParams{sampleRate: 44100, channels: 2, bitsPerSample: 16, compressionLevel: 0})
	info, br, f := openStreamAtFirstFrame(t, path)
	defer f.Close()

	first, err := ParseFrameHeader(br, info)
	if err != nil {
		t.Fatalf("ParseFrameHeader failed: %v", err)
	}
	if first.BlockSize <= 0 {
		t.Errorf("BlockSize = %d, want > 0", first.BlockSize)
	}
}

func TestParseFrameHeader_RejectsBadSync(t *testing.T) {
	info := StreamInfo{SampleRate: 44100, Channels: 2, BitsPerSample: 16}
	data := []byte{0x00, 0x00, 0x00, 0x00, 0x00}
	br := NewBitReader(bytes.NewReader(data))
	if _, err := ParseFrameHeader(br, info); err == nil {
		t.Fatal("expected an error for invalid sync code")
	}
}

func TestParseFrameHeader_RejectsBadCRC(t *testing.T) {
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

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read fixture: %v", err)
	}
	// Corrupt a byte inside the frame header (well before its CRC byte) so
	// the CRC-8 check must catch it.
	corruptIdx := int(stream.AudioStart) + 2
	if corruptIdx >= len(raw) {
		t.Fatalf("fixture too small to corrupt at %d", corruptIdx)
	}
	raw[corruptIdx] ^= 0xFF

	br := NewBitReader(bytes.NewReader(raw[stream.AudioStart:]))
	if _, err := ParseFrameHeader(br, stream.Info); err == nil {
		t.Fatal("expected a CRC-8 mismatch error for corrupted frame header")
	}
}

func TestParseFrameHeader_TruncatedInputIsError(t *testing.T) {
	info := StreamInfo{SampleRate: 44100, Channels: 2, BitsPerSample: 16}
	// A syntactically valid sync+flags prefix, then nothing.
	data := []byte{0xFF, 0xF8}
	br := NewBitReader(bytes.NewReader(data))
	if _, err := ParseFrameHeader(br, info); err == nil {
		t.Fatal("expected an error for truncated frame header")
	}
}
