package store

import (
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/config"
)

// newTempStore returns a fresh *Store with config rooted at a temp directory.
// It mutates the package-global config but the tests do not run in parallel.
func newTempStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	config.Instance.SetUserDataPath(dir)
	return &Store{}
}

func writeJSON(t *testing.T, name, body string) {
	t.Helper()
	path := filepath.Join(config.Instance.GetUserDataPath(), name+".json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

func TestLoadSlice_MissingReturnsEmpty(t *testing.T) {
	s := newTempStore(t)
	got, err := s.LoadSlice("missing")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil {
		t.Fatal("expected empty slice, got nil")
	}
	if len(got) != 0 {
		t.Fatalf("expected empty slice, got len=%d", len(got))
	}
}

func TestLoadSlice_ValidArray(t *testing.T) {
	s := newTempStore(t)
	writeJSON(t, "library", `[{"id":"a"},{"id":"b"}]`)
	got, err := s.LoadSlice("library")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected len=2, got %d", len(got))
	}
}

func TestLoadSlice_WrongTypeReturnsError(t *testing.T) {
	s := newTempStore(t)
	writeJSON(t, "library", `{"oops":"not an array"}`)
	_, err := s.LoadSlice("library")
	if err == nil {
		t.Fatal("expected type-mismatch error, got nil")
	}
}

func TestLoadMap_MissingReturnsEmpty(t *testing.T) {
	s := newTempStore(t)
	got, err := s.LoadMap("missing")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil {
		t.Fatal("expected empty map, got nil")
	}
	if len(got) != 0 {
		t.Fatalf("expected empty map, got len=%d", len(got))
	}
}

func TestLoadMap_ValidObject(t *testing.T) {
	s := newTempStore(t)
	writeJSON(t, "playcounts", `{"/path/a":{"count":3}}`)
	got, err := s.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, ok := got["/path/a"]; !ok {
		t.Fatalf("expected key /path/a, got keys=%v", keys(got))
	}
}

func TestLoadMap_WrongTypeReturnsError(t *testing.T) {
	s := newTempStore(t)
	writeJSON(t, "playcounts", `[1,2,3]`)
	_, err := s.LoadMap("playcounts")
	if err == nil {
		t.Fatal("expected type-mismatch error, got nil")
	}
}

func keys(m map[string]interface{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
