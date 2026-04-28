package lyricssync

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunSidecarDummyPython(t *testing.T) {
	py, err := FindDevelopmentPythonExe()
	if err != nil {
		t.Skip("python3 not on PATH")
	}
	repoRoot := findRepoRoot(t)
	pythonPkg := filepath.Join(repoRoot, "python")
	if _, err := os.Stat(filepath.Join(pythonPkg, "lyrics_sync")); err != nil {
		t.Skip("python/lyrics_sync missing")
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
