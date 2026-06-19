package audioembed

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func findRepoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for dir := wd; ; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}
	t.Fatal("go.mod not found in ancestors")
	return ""
}

func TestRunSidecar_DummyModeReturnsVectors(t *testing.T) {
	repo := findRepoRoot(t)
	pkgRoot := filepath.Join(repo, "python")
	if _, err := os.Stat(filepath.Join(pkgRoot, "audio_embed")); err != nil {
		t.Skipf("python/audio_embed missing: %v", err)
	}
	py, err := resolvePythonExe(pkgRoot)
	if err != nil {
		t.Skipf("python interpreter not resolved: %v", err)
	}

	argv := []string{py, "-m", "audio_embed", "--request", "-"}
	env := append(os.Environ(),
		"PYTHONPATH="+pkgRoot,
		"UX_MUSIC_AUDIO_EMBED_DUMMY=1",
	)

	var lastStage string
	got, err := RunSidecar(context.Background(), Request{
		SongPaths: []string{"/tmp/a.mp3", "/tmp/b.mp3"},
	}, argv, env, func(stage string, _ float64) {
		lastStage = stage
	})
	if err != nil {
		t.Fatalf("RunSidecar: %v", err)
	}
	if !got.Success {
		t.Fatalf("expected success, got %+v", got)
	}
	if !strings.HasPrefix(got.Version, "audio-embed-v0") {
		t.Fatalf("unexpected version: %q", got.Version)
	}
	if len(got.Embeddings) != 2 {
		t.Fatalf("expected 2 embeddings, got %d", len(got.Embeddings))
	}
	for i, e := range got.Embeddings {
		if e.Dim != EmbedDim {
			t.Errorf("embedding %d wrong dim: %d", i, e.Dim)
		}
		if len(e.Vector) != EmbedDim {
			t.Errorf("embedding %d vector len: %d", i, len(e.Vector))
		}
	}
	if lastStage == "" {
		t.Log("note: no progress stage observed (acceptable but unusual)")
	}
}

func TestRunSidecar_RejectsEmptyArgv(t *testing.T) {
	_, err := RunSidecar(context.Background(), Request{SongPaths: []string{"/x"}}, nil, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty-argv error, got: %v", err)
	}
}

func TestRunSidecar_PropagatesSidecarError(t *testing.T) {
	repo := findRepoRoot(t)
	pkgRoot := filepath.Join(repo, "python")
	if _, err := os.Stat(filepath.Join(pkgRoot, "audio_embed")); err != nil {
		t.Skipf("python/audio_embed missing: %v", err)
	}
	py, err := resolvePythonExe(pkgRoot)
	if err != nil {
		t.Skipf("python interpreter not resolved: %v", err)
	}
	argv := []string{py, "-m", "audio_embed", "--request", "-"}
	env := append(os.Environ(),
		"PYTHONPATH="+pkgRoot,
		"UX_MUSIC_AUDIO_EMBED_DUMMY=1",
	)
	got, err := RunSidecar(context.Background(), Request{SongPaths: nil}, argv, env, nil)
	if err != nil {
		t.Fatalf("expected sidecar to return result (not Go error) for bad req: %v", err)
	}
	if got.Success {
		t.Fatalf("expected success=false for empty request, got %+v", got)
	}
	if got.Error == "" {
		t.Fatalf("expected non-empty error message")
	}
}
