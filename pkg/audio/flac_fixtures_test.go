// This file provides a minimal FLAC fixture generator for this package's
// tests, duplicated (rather than imported) from
// pkg/audio/flac/fixtures_test.go, since Go test helpers cannot be shared
// across package boundaries. Fixtures are generated at test time via the
// ffmpeg and flac CLIs and are never committed to the repository.
package audio

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

var flacFixtureDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "ux-music-audio-flac-fixtures-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "flac fixtures: failed to create temp dir: %v\n", err)
		os.Exit(1)
	}
	flacFixtureDir = dir
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// lookFlacTool resolves a CLI tool by name, falling back to the common
// Homebrew prefix, following the precedent at server/app_remote_relay_test.go:72.
func lookFlacTool(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	fallback := "/opt/homebrew/bin/" + name
	if _, err := os.Stat(fallback); err == nil {
		return fallback
	}
	return ""
}

// requireFFmpegAndFlacForAudioTest skips the test when either CLI tool
// needed to generate real FLAC fixtures is unavailable.
func requireFFmpegAndFlacForAudioTest(t *testing.T) (ffmpegPath, flacPath string) {
	t.Helper()
	ffmpegPath = lookFlacTool("ffmpeg")
	if ffmpegPath == "" {
		t.Skip("ffmpeg not available on PATH; skipping FLAC fixture test")
	}
	flacPath = lookFlacTool("flac")
	if flacPath == "" {
		t.Skip("flac CLI not available on PATH; skipping FLAC fixture test")
	}
	return ffmpegPath, flacPath
}

// generateAudioFlacFixture builds a FLAC file at the given sample rate, bit
// depth and channel count, mixing a sine tone and white noise so the
// content is non-trivial (a pure tone or silence would not exercise real
// residual coding). durationSeconds defaults to 2 when zero.
func generateAudioFlacFixture(t *testing.T, sampleRate, channels, bitsPerSample int, durationSeconds int) string {
	t.Helper()
	ffmpegPath, flacPath := requireFFmpegAndFlacForAudioTest(t)
	if durationSeconds == 0 {
		durationSeconds = 2
	}

	key := fmt.Sprintf("adapter_%dhz_%dch_%dbit_%ds", sampleRate, channels, bitsPerSample, durationSeconds)
	wavPath := filepath.Join(flacFixtureDir, key+".wav")
	flacOutPath := filepath.Join(flacFixtureDir, key+".flac")
	if _, err := os.Stat(flacOutPath); err == nil {
		return flacOutPath
	}

	codec := "pcm_s16le"
	switch bitsPerSample {
	case 16:
		codec = "pcm_s16le"
	case 24:
		codec = "pcm_s24le"
	default:
		t.Fatalf("generateAudioFlacFixture: unsupported bitsPerSample %d", bitsPerSample)
	}

	filter := fmt.Sprintf(
		"sine=frequency=440:duration=%d[a];anoisesrc=duration=%d:color=white[b];[a][b]amix=inputs=2:duration=shortest:weights=1 0.35[out]",
		durationSeconds, durationSeconds,
	)
	ffmpegArgs := []string{
		"-y", "-hide_banner", "-loglevel", "error",
		"-filter_complex", filter,
		"-map", "[out]",
		"-ar", strconv.Itoa(sampleRate),
		"-ac", strconv.Itoa(channels),
		"-c:a", codec,
		wavPath,
	}
	cmd := exec.Command(ffmpegPath, ffmpegArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg fixture generation failed: %v\n%s", err, out)
	}

	cmd = exec.Command(flacPath, "-f", "--totally-silent", "-5", "-o", flacOutPath, wavPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("flac encode of fixture failed: %v\n%s", err, out)
	}

	return flacOutPath
}

// prependAudioID3v2 writes a copy of srcFlacPath prefixed with a synthetic,
// minimal ID3v2.3 header (no frames, no footer) so tests can assert that
// the player's FLAC decoding path never modifies the original file (the
// regression lock for the deleted remux-on-open behaviour).
func prependAudioID3v2(t *testing.T, srcFlacPath string) string {
	t.Helper()
	body, err := os.ReadFile(srcFlacPath)
	if err != nil {
		t.Fatalf("failed to read fixture for ID3v2 prefixing: %v", err)
	}

	const tagBodyLen = 128
	header := make([]byte, 10)
	copy(header[0:3], "ID3")
	header[3] = 3
	header[4] = 0
	header[5] = 0
	size := tagBodyLen
	header[6] = byte((size >> 21) & 0x7F)
	header[7] = byte((size >> 14) & 0x7F)
	header[8] = byte((size >> 7) & 0x7F)
	header[9] = byte(size & 0x7F)

	tagBody := make([]byte, tagBodyLen)

	out := make([]byte, 0, len(header)+len(tagBody)+len(body))
	out = append(out, header...)
	out = append(out, tagBody...)
	out = append(out, body...)

	dstPath := filepath.Join(flacFixtureDir, filepath.Base(srcFlacPath)+".id3.flac")
	if err := os.WriteFile(dstPath, out, 0o600); err != nil {
		t.Fatalf("failed to write ID3v2-prefixed fixture: %v", err)
	}
	return dstPath
}
