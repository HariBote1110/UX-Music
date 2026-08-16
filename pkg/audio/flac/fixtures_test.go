package flac

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
)

// fixtureDir is a single temp directory shared by every test in this
// package's process, created in TestMain and removed at exit. Fixtures are
// never written into the repository.
var fixtureDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "ux-music-flac-fixtures-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "flac fixtures: failed to create temp dir: %v\n", err)
		os.Exit(1)
	}
	fixtureDir = dir
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// fixtureParams identifies one generated FLAC fixture. Values here are the
// knobs the task asks tests to be parameterised over.
type fixtureParams struct {
	sampleRate       int
	channels         int
	bitsPerSample    int
	compressionLevel int
	durationSeconds  int
}

var (
	fixtureMu    sync.Mutex
	fixtureCache = map[fixtureParams]string{}
)

// lookTool resolves a CLI tool by name, falling back to the common Homebrew
// prefix, following the precedent at server/app_remote_relay_test.go:72.
func lookTool(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	fallback := "/opt/homebrew/bin/" + name
	if _, err := os.Stat(fallback); err == nil {
		return fallback
	}
	return ""
}

// requireFFmpegAndFlacForTest skips the test when either CLI tool needed to
// generate real FLAC fixtures is unavailable.
func requireFFmpegAndFlacForTest(t *testing.T) (ffmpegPath, flacPath string) {
	t.Helper()
	ffmpegPath = lookTool("ffmpeg")
	if ffmpegPath == "" {
		t.Skip("ffmpeg not available on PATH; skipping FLAC fixture test")
	}
	flacPath = lookTool("flac")
	if flacPath == "" {
		t.Skip("flac CLI not available on PATH; skipping FLAC fixture test")
	}
	return ffmpegPath, flacPath
}

// generateFixture builds (or returns a memoised) FLAC file matching p: a
// mix of a sine tone and white noise, encoded through the reference `flac`
// CLI. Pure silence or a pure sine would produce degenerate residuals, so
// the content is deliberately non-trivial.
func generateFixture(t *testing.T, p fixtureParams) string {
	t.Helper()
	ffmpegPath, flacPath := requireFFmpegAndFlacForTest(t)
	if p.durationSeconds == 0 {
		p.durationSeconds = 3
	}

	fixtureMu.Lock()
	defer fixtureMu.Unlock()
	if path, ok := fixtureCache[p]; ok {
		return path
	}

	key := fmt.Sprintf("fx_%dhz_%dch_%dbit_c%d_%ds", p.sampleRate, p.channels, p.bitsPerSample, p.compressionLevel, p.durationSeconds)
	wavPath := filepath.Join(fixtureDir, key+".wav")
	flacOutPath := filepath.Join(fixtureDir, key+".flac")

	codec := "pcm_s16le"
	switch p.bitsPerSample {
	case 16:
		codec = "pcm_s16le"
	case 24:
		codec = "pcm_s24le"
	default:
		t.Fatalf("generateFixture: unsupported bitsPerSample %d", p.bitsPerSample)
	}

	filter := fmt.Sprintf(
		"sine=frequency=440:duration=%d[a];anoisesrc=duration=%d:color=white[b];[a][b]amix=inputs=2:duration=shortest:weights=1 0.35[out]",
		p.durationSeconds, p.durationSeconds,
	)

	ffmpegArgs := []string{
		"-y", "-hide_banner", "-loglevel", "error",
		"-filter_complex", filter,
		"-map", "[out]",
		"-ar", strconv.Itoa(p.sampleRate),
		"-ac", strconv.Itoa(p.channels),
		"-c:a", codec,
		wavPath,
	}
	cmd := exec.Command(ffmpegPath, ffmpegArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg fixture generation failed: %v\n%s", err, out)
	}

	flacArgs := []string{
		"-f", "--totally-silent",
		fmt.Sprintf("-%d", p.compressionLevel),
		"-o", flacOutPath,
		wavPath,
	}
	cmd = exec.Command(flacPath, flacArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("flac encode of fixture failed: %v\n%s", err, out)
	}

	fixtureCache[p] = flacOutPath
	return flacOutPath
}

// prependID3v2 writes a copy of srcFlacPath prefixed with a synthetic,
// minimal ID3v2.3 header (no frames, no footer) so tests can assert that
// stream parsing detects and skips it natively.
func prependID3v2(t *testing.T, srcFlacPath string) string {
	t.Helper()
	body, err := os.ReadFile(srcFlacPath)
	if err != nil {
		t.Fatalf("failed to read fixture for ID3v2 prefixing: %v", err)
	}

	// A tag body of 128 bytes of padding, syncsafe-encoded (7 bits/byte).
	const tagBodyLen = 128
	header := make([]byte, 10)
	copy(header[0:3], "ID3")
	header[3] = 3 // version 2.3
	header[4] = 0 // revision
	header[5] = 0 // flags: no footer, no unsync, no extended header
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

	dstPath := filepath.Join(fixtureDir, filepath.Base(srcFlacPath)+".id3.flac")
	if err := os.WriteFile(dstPath, out, 0o600); err != nil {
		t.Fatalf("failed to write ID3v2-prefixed fixture: %v", err)
	}
	return dstPath
}
