package lyricssync

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"ux-music-sidecar/internal/config"
)

func TestExtractVocalWithMLUsesCustomSeparator(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	separator := createFakeCustomVocalSeparator(t)
	t.Setenv(envVocalSeparatorPath, separator)

	workDir := t.TempDir()
	outputPath := filepath.Join(workDir, "vocal-ml.wav")
	if err := extractVocalWithML(context.Background(), songPath, workDir, outputPath); err != nil {
		t.Fatalf("extractVocalWithML returned error: %v", err)
	}
	if _, err := os.Stat(outputPath); err != nil {
		t.Fatalf("output file not found: %v", err)
	}
}

func TestExtractVocalWithMLUsesDemucsWhenAvailable(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	demucsPath := createFakeDemucsScript(t)
	demucsDir := filepath.Dir(demucsPath)
	originalPath := os.Getenv("PATH")
	t.Setenv("PATH", demucsDir+":"+originalPath)
	t.Setenv(envVocalSeparatorPath, "")

	workDir := t.TempDir()
	outputPath := filepath.Join(workDir, "vocal-ml.wav")
	if err := extractVocalWithML(context.Background(), songPath, workDir, outputPath); err != nil {
		t.Fatalf("extractVocalWithML returned error: %v", err)
	}
	if _, err := os.Stat(outputPath); err != nil {
		t.Fatalf("output file not found: %v", err)
	}
}

func TestExtractVocalWithMLFailsWhenNoSeparator(t *testing.T) {
	songPath := createDummyAudioFile(t)
	t.Setenv(envVocalSeparatorPath, "")
	t.Setenv("PATH", t.TempDir())

	workDir := t.TempDir()
	outputPath := filepath.Join(workDir, "vocal-ml.wav")
	err := extractVocalWithML(context.Background(), songPath, workDir, outputPath)
	if err == nil {
		t.Fatalf("extractVocalWithML should fail when no separator is available")
	}
	if !strings.Contains(err.Error(), "demucs") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveDemucsPathFromEnv(t *testing.T) {
	demucsPath := createFakeDemucsScript(t)
	t.Setenv(envDemucsPath, demucsPath)

	resolved, err := resolveDemucsPath()
	if err != nil {
		t.Fatalf("resolveDemucsPath returned error: %v", err)
	}
	if resolved != demucsPath {
		t.Fatalf("resolved=%s want=%s", resolved, demucsPath)
	}
}

func TestResolveDemucsPathInvalidEnv(t *testing.T) {
	t.Setenv(envDemucsPath, filepath.Join(t.TempDir(), "missing-demucs"))

	_, err := resolveDemucsPath()
	if err == nil {
		t.Fatalf("resolveDemucsPath should fail with invalid env path")
	}
	if !strings.Contains(err.Error(), envDemucsPath) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildDemucsModelCandidatesFromQuantisedModel(t *testing.T) {
	candidates := buildDemucsModelCandidates("mdx_extra_q")
	if len(candidates) < 2 {
		t.Fatalf("unexpected candidates: %+v", candidates)
	}
	if candidates[0] != "mdx_extra_q" {
		t.Fatalf("first candidate=%s", candidates[0])
	}
	if candidates[1] != "mdx_extra" {
		t.Fatalf("second candidate=%s", candidates[1])
	}
}

func TestRunDemucsVocalSeparatorFallsBackWhenDiffqMissing(t *testing.T) {
	songPath := createDummyAudioFile(t)
	ffmpeg := createFakeFFmpegScript(t)
	oldFFmpeg := config.FFmpegPath
	oldFFprobe := config.FFprobePath
	config.SetFFmpegPaths(ffmpeg, oldFFprobe)
	t.Cleanup(func() {
		config.SetFFmpegPaths(oldFFmpeg, oldFFprobe)
	})

	demucsPath := createFakeDemucsWithDiffqFallbackScript(t)
	t.Setenv(envDemucsPath, demucsPath)
	t.Setenv(envDemucsModel, "mdx_extra_q")

	workDir := t.TempDir()
	outputPath := filepath.Join(workDir, "vocal-ml.wav")
	if err := runDemucsVocalSeparator(context.Background(), songPath, workDir, outputPath); err != nil {
		t.Fatalf("runDemucsVocalSeparator returned error: %v", err)
	}
	if _, err := os.Stat(outputPath); err != nil {
		t.Fatalf("output file not found: %v", err)
	}
}

func createFakeCustomVocalSeparator(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fake-vocal-separator.sh")
	script := `#!/bin/sh
out="$2"
if [ -z "$out" ]; then
  echo "missing output path" 1>&2
  exit 1
fi
: > "$out"
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to create fake separator: %v", err)
	}
	return path
}

func createFakeDemucsScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "demucs")
	script := `#!/bin/sh
out=""
input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      out="$2"
      shift 2
      ;;
    --two-stems=vocals)
      shift 1
      ;;
    *)
      input="$1"
      shift 1
      ;;
  esac
done

if [ -z "$out" ] || [ -z "$input" ]; then
  echo "missing args" 1>&2
  exit 1
fi

name=$(basename "$input")
base="${name%.*}"
mkdir -p "$out/htdemucs/$base"
: > "$out/htdemucs/$base/vocals.wav"
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to create fake demucs script: %v", err)
	}
	return path
}

func createFakeDemucsWithDiffqFallbackScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "demucs")
	script := `#!/bin/sh
out=""
input=""
model=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      out="$2"
      shift 2
      ;;
    --name)
      model="$2"
      shift 2
      ;;
    --jobs|--two-stems=vocals)
      shift 1
      ;;
    *)
      input="$1"
      shift 1
      ;;
  esac
done

if [ -z "$out" ] || [ -z "$input" ] || [ -z "$model" ]; then
  echo "missing args" 1>&2
  exit 1
fi

if [ "$model" = "mdx_extra_q" ]; then
  echo "FATAL: Trying to use DiffQ, but diffq is not installed." 1>&2
  exit 1
fi

name=$(basename "$input")
base="${name%.*}"
mkdir -p "$out/$model/$base"
: > "$out/$model/$base/vocals.wav"
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to create fake demucs fallback script: %v", err)
	}
	return path
}
