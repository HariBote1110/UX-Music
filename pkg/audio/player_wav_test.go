package audio

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"testing"

	audioformat "github.com/go-audio/audio"
	wavcodec "github.com/go-audio/wav"
)

func TestWavSampleToInt16_8bitUnsigned(t *testing.T) {
	if got := wavSampleToInt16(0, 8); got != -32768 {
		t.Fatalf("expected -32768, got %d", got)
	}
	if got := wavSampleToInt16(128, 8); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
	if got := wavSampleToInt16(255, 8); got != 32512 {
		t.Fatalf("expected 32512, got %d", got)
	}
}

func TestWavSampleToInt16_24bitScaling(t *testing.T) {
	if got := wavSampleToInt16(8388607, 24); got != 32767 {
		t.Fatalf("expected 32767, got %d", got)
	}
	if got := wavSampleToInt16(-8388608, 24); got != -32768 {
		t.Fatalf("expected -32768, got %d", got)
	}
	if got := wavSampleToInt16(0, 24); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
}

func TestWAVDecoder_LengthUsesPCMBytes(t *testing.T) {
	reader := mustBuildPCM16WAVReader(t, []int{100, 200, 300, 400}, 44100, 1)

	dec, err := newWAVDecoder(reader)
	if err != nil {
		t.Fatalf("failed to create WAV decoder: %v", err)
	}

	if got, want := dec.Length(), int64(4); got != want {
		t.Fatalf("expected length %d, got %d", want, got)
	}
}

func TestWAVDecoder_SeekJumpsToTargetSample(t *testing.T) {
	reader := mustBuildPCM16WAVReader(t, []int{1000, 2000, 3000, 4000, 5000}, 44100, 1)

	dec, err := newWAVDecoder(reader)
	if err != nil {
		t.Fatalf("failed to create WAV decoder: %v", err)
	}

	if err := dec.Seek(3); err != nil {
		t.Fatalf("seek failed: %v", err)
	}

	buf := make([]byte, 4)
	n, err := dec.Read(buf)
	if err != nil {
		t.Fatalf("read after seek failed: %v", err)
	}
	if n < 2 {
		t.Fatalf("expected at least 2 bytes after seek, got %d", n)
	}

	got := int16(binary.LittleEndian.Uint16(buf[:2]))
	if want := int16(4000); got != want {
		t.Fatalf("expected sample %d after seek, got %d", want, got)
	}
}

func mustBuildPCM16WAVReader(t *testing.T, samples []int, sampleRate int, channels int) *bytes.Reader {
	t.Helper()

	tmpFile, err := os.CreateTemp("", "uxmusic-wav-*.wav")
	if err != nil {
		t.Fatalf("failed to create temporary file: %v", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	encoder := wavcodec.NewEncoder(tmpFile, sampleRate, 16, channels, 1)
	intBuffer := &audioformat.IntBuffer{
		Data:           append([]int(nil), samples...),
		Format:         &audioformat.Format{NumChannels: channels, SampleRate: sampleRate},
		SourceBitDepth: 16,
	}
	if err := encoder.Write(intBuffer); err != nil {
		t.Fatalf("failed to write WAV: %v", err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatalf("failed to close WAV encoder: %v", err)
	}
	if _, err := tmpFile.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("failed to rewind temporary WAV file: %v", err)
	}

	data, err := io.ReadAll(tmpFile)
	if err != nil {
		t.Fatalf("failed to read temporary WAV file: %v", err)
	}

	return bytes.NewReader(data)
}
