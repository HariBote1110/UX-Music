// This file tests Decoder.SeekSample: exact equivalence against linear
// decode-then-skip, for both SEEKTABLE and binary-search code paths.
package flac

import (
	"errors"
	"io"
	"os"
	"testing"
)

// decodeFromSample opens flacPath, seeks to targetSample, and decodes every
// remaining sample, returning the per-channel result plus the StreamInfo.
func decodeFromSample(t *testing.T, flacPath string, targetSample int64) ([][]int32, StreamInfo) {
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

	if err := dec.SeekSample(targetSample); err != nil {
		t.Fatalf("SeekSample(%d) failed: %v", targetSample, err)
	}

	info := dec.Info()
	out := make([][]int32, info.Channels)
	for {
		frame, err := dec.ReadFrame()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("ReadFrame after seek failed: %v", err)
		}
		for ch := 0; ch < info.Channels; ch++ {
			out[ch] = append(out[ch], frame.Samples[ch]...)
		}
	}
	return out, info
}

// assertSeekMatchesLinearSkip decodes flacPath from the start, decodes it
// again via SeekSample(target), and asserts the seeked stream is exactly
// the tail of the linear one from target onward.
func assertSeekMatchesLinearSkip(t *testing.T, flacPath string, target int64) {
	t.Helper()
	linear, info := decodeAllOurs(t, flacPath)
	seeked, seekInfo := decodeFromSample(t, flacPath, target)

	if seekInfo.Channels != info.Channels {
		t.Fatalf("channel count mismatch: linear %d, seeked %d", info.Channels, seekInfo.Channels)
	}

	clampedTarget := target
	if clampedTarget > info.TotalSamples {
		clampedTarget = info.TotalSamples
	}

	for ch := 0; ch < info.Channels; ch++ {
		want := linear[ch][clampedTarget:]
		got := seeked[ch]
		if len(got) != len(want) {
			t.Fatalf("channel %d: seeked from %d produced %d samples, want %d", ch, target, len(got), len(want))
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("channel %d: first mismatch at sample %d (absolute %d): got %d, want %d",
					ch, i, clampedTarget+int64(i), got[i], want[i])
			}
		}
	}
}

// seekTargets returns a representative set of seek targets for a stream of
// the given total length and nominal block size: the very start, a
// mid-frame position, a position exactly on a frame boundary, and a
// position near (but not past) the end.
func seekTargets(totalSamples int64, blockSize int) []int64 {
	targets := []int64{0}
	if blockSize > 4 {
		targets = append(targets, int64(blockSize/2)) // mid-frame
		targets = append(targets, int64(blockSize*2)) // on a frame boundary
		targets = append(targets, int64(blockSize)+3) // just past a boundary
	}
	if totalSamples > 10 {
		targets = append(targets, totalSamples-10) // near the end
	}
	return targets
}

// firstFrameBlockSize decodes just the first frame to learn the stream's
// nominal block size, used to pick seek targets relative to real frame
// boundaries.
func firstFrameBlockSize(t *testing.T, flacPath string) int {
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

	frame, err := dec.ReadFrame()
	if err != nil {
		t.Fatalf("ReadFrame failed: %v", err)
	}
	return frame.BlockSize
}

func TestSeekSample_EquivalentToLinearDecode_WithSeekTable(t *testing.T) {
	p := fixtureParams{44100, 2, 16, 5, 2}
	path := generateFixture(t, p) // flac CLI writes a SEEKTABLE by default
	blockSize := firstFrameBlockSize(t, path)

	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	stream, err := ParseStream(f)
	f.Close()
	if err != nil {
		t.Fatalf("failed to parse stream: %v", err)
	}
	if len(stream.SeekTableRaw) == 0 {
		t.Fatal("expected fixture to carry a SEEKTABLE block, found none")
	}

	for _, target := range seekTargets(stream.Info.TotalSamples, blockSize) {
		target := target
		t.Run("", func(t *testing.T) {
			assertSeekMatchesLinearSkip(t, path, target)
		})
	}
}

func TestSeekSample_EquivalentToLinearDecode_NoSeekTable(t *testing.T) {
	p := fixtureParams{44100, 2, 16, 5, 2}
	path := generateFixtureWithFlacArgs(t, p, []string{"--no-seektable"}, "_noseektable")
	blockSize := firstFrameBlockSize(t, path)

	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("failed to open fixture: %v", err)
	}
	stream, err := ParseStream(f)
	f.Close()
	if err != nil {
		t.Fatalf("failed to parse stream: %v", err)
	}
	if len(stream.SeekTableRaw) != 0 {
		t.Fatal("expected fixture to carry no SEEKTABLE block")
	}

	for _, target := range seekTargets(stream.Info.TotalSamples, blockSize) {
		target := target
		t.Run("", func(t *testing.T) {
			assertSeekMatchesLinearSkip(t, path, target)
		})
	}
}

func TestSeekSample_ZeroAlwaysWorks(t *testing.T) {
	matrix := []struct {
		name string
		p    fixtureParams
	}{
		{"stereo_16bit", fixtureParams{44100, 2, 16, 5, 1}},
		{"mono_16bit", fixtureParams{44100, 1, 16, 5, 1}},
		{"96k_24bit", fixtureParams{96000, 2, 24, 5, 1}},
	}
	for _, tc := range matrix {
		t.Run(tc.name, func(t *testing.T) {
			path := generateFixture(t, tc.p)
			assertSeekMatchesLinearSkip(t, path, 0)
		})
	}
}

func TestSeekSample_NegativeSampleReturnsError(t *testing.T) {
	p := fixtureParams{44100, 2, 16, 5, 1}
	path := generateFixture(t, p)

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

	if err := dec.SeekSample(-1); err == nil {
		t.Fatal("expected an error seeking to a negative sample, got nil")
	}
}

func TestSeekSample_BeyondTotalSamplesReturnsError(t *testing.T) {
	p := fixtureParams{44100, 2, 16, 5, 1}
	path := generateFixture(t, p)

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

	beyond := dec.Info().TotalSamples + 1000
	if err := dec.SeekSample(beyond); err == nil {
		t.Fatalf("expected an error seeking to sample %d (beyond total %d), got nil", beyond, dec.Info().TotalSamples)
	}
}
