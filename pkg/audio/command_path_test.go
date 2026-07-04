package audio

import (
	"os"
	"path/filepath"
	"testing"
)

// TestSetFFmpegPathsInjectsResolvedCommandPath verifies that pkg/audio can
// receive its ffmpeg/ffprobe executable paths from an external caller
// (e.g. server/) without depending on internal/config directly.
func TestSetFFmpegPathsInjectsResolvedCommandPath(t *testing.T) {
	dir := t.TempDir()

	ffmpegPath := filepath.Join(dir, "ffmpeg")
	if err := os.WriteFile(ffmpegPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("failed to create fake ffmpeg binary: %v", err)
	}

	ffprobePath := filepath.Join(dir, "ffprobe")
	if err := os.WriteFile(ffprobePath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("failed to create fake ffprobe binary: %v", err)
	}

	t.Cleanup(func() {
		SetFFmpegPaths("", "")
		resolvedCommandPaths.Delete("ffmpeg")
		resolvedCommandPaths.Delete("ffprobe")
	})

	SetFFmpegPaths(ffmpegPath, ffprobePath)

	resolvedFFmpeg, err := resolveCommandPath("ffmpeg")
	if err != nil {
		t.Fatalf("resolveCommandPath(ffmpeg) returned error: %v", err)
	}
	if resolvedFFmpeg != ffmpegPath {
		t.Errorf("resolveCommandPath(ffmpeg) = %q, want %q", resolvedFFmpeg, ffmpegPath)
	}

	resolvedFFprobe, err := resolveCommandPath("ffprobe")
	if err != nil {
		t.Fatalf("resolveCommandPath(ffprobe) returned error: %v", err)
	}
	if resolvedFFprobe != ffprobePath {
		t.Errorf("resolveCommandPath(ffprobe) = %q, want %q", resolvedFFprobe, ffprobePath)
	}
}
