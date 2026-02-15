package lyricssync

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"ux-music-sidecar/internal/config"
)

func TestSyncFailsWhenLinesAreEmpty(t *testing.T) {
	songPath := createDummyAudioFile(t)
	syncer := NewSyncer()

	result := syncer.Sync(Request{
		SongPath: songPath,
		Lines:    []string{"", "  "},
		Language: "auto-ja",
		Profile:  "fast",
	})

	if result.Success {
		t.Fatalf("result.Success = true, want false")
	}
	if !strings.Contains(result.Error, "歌詞行") {
		t.Fatalf("unexpected error: %s", result.Error)
	}
}

func TestSyncFailsWhenCLIPathIsInvalid(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	t.Setenv(envCLIPath, filepath.Join(t.TempDir(), "missing-whisper-cli"))
	modelPath, _ := createModelFixtures(t)
	t.Setenv(envModelPath, modelPath)

	syncer := NewSyncer()
	result := syncer.Sync(Request{
		SongPath: songPath,
		Lines:    []string{"hello"},
		Language: "auto-ja",
		Profile:  "fast",
	})

	if result.Success {
		t.Fatalf("result.Success = true, want false")
	}
	if !strings.Contains(result.Error, "whisper-cli") {
		t.Fatalf("unexpected error: %s", result.Error)
	}
}

func TestSyncFailsWhenModelPathIsInvalid(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	cliPath := createFakeWhisperScript(t)
	t.Setenv(envCLIPath, cliPath)
	t.Setenv(envModelPath, filepath.Join(t.TempDir(), "missing-model.bin"))

	syncer := NewSyncer()
	result := syncer.Sync(Request{
		SongPath: songPath,
		Lines:    []string{"hello"},
		Language: "auto-ja",
		Profile:  "fast",
	})

	if result.Success {
		t.Fatalf("result.Success = true, want false")
	}
	if !strings.Contains(result.Error, "モデル") {
		t.Fatalf("unexpected error: %s", result.Error)
	}
}

func TestSyncWithFakeWhisperAndFFmpeg(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	cliPath := createFakeWhisperScript(t)
	modelPath, _ := createModelFixtures(t)

	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	t.Setenv(envCLIPath, cliPath)
	t.Setenv(envModelPath, modelPath)

	syncer := NewSyncer()
	result := syncer.Sync(Request{
		SongPath: songPath,
		Lines:    []string{"こんにちは", "世界"},
		Language: "auto-ja",
		Profile:  "fast",
	})

	if !result.Success {
		t.Fatalf("result.Success = false, error=%s", result.Error)
	}
	if len(result.Lines) != 2 {
		t.Fatalf("len(result.Lines)=%d, want 2", len(result.Lines))
	}
	if result.MatchedCount < 2 {
		t.Fatalf("MatchedCount=%d, want at least 2", result.MatchedCount)
	}
	if result.Lines[0].Timestamp >= result.Lines[1].Timestamp {
		t.Fatalf("timestamps are not increasing: %+v", result.Lines)
	}
}

func createDummyAudioFile(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "song.m4a")
	if err := os.WriteFile(path, []byte("dummy"), 0o644); err != nil {
		t.Fatalf("failed to create dummy audio: %v", err)
	}
	return path
}

func createModelFixtures(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	modelPath := filepath.Join(dir, "ggml-base.bin")
	if err := os.WriteFile(modelPath, []byte("model"), 0o644); err != nil {
		t.Fatalf("failed to create model file: %v", err)
	}

	coreMLDir := filepath.Join(dir, "ggml-base-encoder.mlmodelc")
	if err := os.MkdirAll(coreMLDir, 0o755); err != nil {
		t.Fatalf("failed to create coreml dir: %v", err)
	}
	return modelPath, coreMLDir
}

func createFakeFFmpegScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fake-ffmpeg.sh")
	script := `#!/bin/sh
out=""
for arg in "$@"; do
  out="$arg"
done
: > "$out"
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to create fake ffmpeg script: %v", err)
	}
	return path
}

func createFakeWhisperScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "whisper-cli")
	script := `#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -of|--output-file)
      out="$2"
      shift 2
      ;;
    *)
      shift 1
      ;;
  esac
done

if [ -z "$out" ]; then
  echo "missing -of argument" 1>&2
  exit 1
fi

cat > "${out}.json" <<'JSON'
{
  "segments": [
    { "start": 0.50, "end": 1.20, "text": "こんにちは" },
    { "start": 1.70, "end": 2.40, "text": "世界" }
  ]
}
JSON
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to create fake whisper script: %v", err)
	}
	return path
}
