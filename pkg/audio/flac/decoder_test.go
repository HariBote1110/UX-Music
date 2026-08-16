package flac

import (
	"errors"
	"io"
	"os"
	"testing"
)

func TestDecoder_ReadFrame_RoundTripsWholeStream(t *testing.T) {
	path := generateFixture(t, fixtureParams{
		sampleRate:       44100,
		channels:         2,
		bitsPerSample:    16,
		compressionLevel: 5,
		durationSeconds:  1,
	})

	f, err := os.Open(path)
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
	if info.Channels != 2 || info.BitsPerSample != 16 || info.SampleRate != 44100 {
		t.Fatalf("unexpected Info(): %+v", info)
	}

	var totalSamples int64
	frameCount := 0
	for {
		frame, err := dec.ReadFrame()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("ReadFrame failed after %d frames: %v", frameCount, err)
		}
		if len(frame.Samples) != 2 {
			t.Fatalf("frame %d: got %d channels, want 2", frameCount, len(frame.Samples))
		}
		for ch, samples := range frame.Samples {
			if len(samples) != frame.BlockSize {
				t.Fatalf("frame %d channel %d: got %d samples, want block size %d", frameCount, ch, len(samples), frame.BlockSize)
			}
		}
		totalSamples += int64(frame.BlockSize)
		frameCount++
	}

	if frameCount == 0 {
		t.Fatal("decoded zero frames")
	}
	if totalSamples != info.TotalSamples {
		t.Fatalf("decoded %d total samples, STREAMINFO says %d", totalSamples, info.TotalSamples)
	}
}
