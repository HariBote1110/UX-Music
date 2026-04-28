package lyricssync

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRunSidecarDummyPython(t *testing.T) {
	repoRoot := findRepoRoot(t)
	pythonPkg := filepath.Join(repoRoot, "python")
	if _, err := os.Stat(filepath.Join(pythonPkg, "lyrics_sync")); err != nil {
		t.Skip("python/lyrics_sync missing")
	}

	py, err := ResolveLyricsSidecarPythonExe(pythonPkg)
	if err != nil {
		t.Skipf("python interpreter not resolved: %v", err)
	}

	argv := []string{py, "-m", "lyrics_sync", "--request", "-"}
	env := []string{
		"PYTHONPATH=" + pythonPkg,
		"UX_MUSIC_MODEL_CACHE=/tmp",
		"UX_MUSIC_HF_DOWNLOAD=none",
		"UX_MUSIC_LYRICS_SYNC_DUMMY=1",
	}
	req := Request{
		SongPath: "/dev/null",
		Lines:    []string{"hello"},
		Language: "auto",
		Profile:  "fast",
	}

	var progressed bool
	got, err := RunSidecar(context.Background(), req, argv, env, func(string, float64) {
		progressed = true
	}, nil)
	if err != nil {
		t.Fatalf("RunSidecar: %v", err)
	}
	if !got.Success {
		t.Fatalf("expected success, got %+v", got)
	}
	if progressed {
		t.Log("progress stderr received")
	}
}

func TestRunSidecarRejectsBadArgv(t *testing.T) {
	_, err := RunSidecar(context.Background(), Request{}, []string{}, nil, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty argv error: %v", err)
	}
}

func TestRunSidecarDummySwift(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("swift sidecar is macOS only")
	}

	repoRoot := findRepoRoot(t)
	swiftPkg := filepath.Join(repoRoot, "swift", "lyrics-sync")
	if _, err := os.Stat(filepath.Join(swiftPkg, "Package.swift")); err != nil {
		t.Skip("swift/lyrics-sync missing")
	}
	swiftExe, err := exec.LookPath("swift")
	if err != nil {
		t.Skipf("swift not found: %v", err)
	}

	argv := []string{
		swiftExe,
		"run",
		"--package-path",
		swiftPkg,
		"lyrics-sync-swift",
		"--request",
		"-",
	}
	env := []string{
		"UX_MUSIC_MODEL_CACHE=/tmp",
		"UX_MUSIC_HF_DOWNLOAD=none",
		"UX_MUSIC_LYRICS_SYNC_DUMMY=1",
	}
	req := Request{
		SongPath: "/dev/null",
		Lines:    []string{"hello"},
		Language: "auto",
		Profile:  "fast",
	}

	got, err := RunSidecar(context.Background(), req, argv, env, nil, nil)
	if err != nil {
		t.Fatalf("RunSidecar swift: %v", err)
	}
	if !got.Success {
		t.Fatalf("expected success, got %+v", got)
	}
	if got.DetectedBy == "" {
		t.Fatal("expected detectedBy")
	}
}

func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(".")
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found")
		}
		dir = parent
	}
}
