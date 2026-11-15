package store

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
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

func TestSave_CreatesMissingUserDataDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "missing", "ux-music")
	config.Instance.SetUserDataPath(dir)
	s := &Store{}

	if err := s.Save("settings", map[string]interface{}{"ok": true}); err != nil {
		t.Fatalf("save with missing directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err != nil {
		t.Fatalf("expected settings file to be written: %v", err)
	}
}

func keys(m map[string]interface{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestUpdateMap_ConcurrentUpdatesKeepAllKeys(t *testing.T) {
	s := newTempStore(t)
	const workers = 50
	var wg sync.WaitGroup
	errs := make(chan error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			key := fmt.Sprintf("key-%03d", i)
			errs <- s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
				m[key] = i
				return true, nil
			})
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("UpdateMap: %v", err)
		}
	}
	got, err := s.LoadMap("prefs")
	if err != nil {
		t.Fatalf("LoadMap: %v", err)
	}
	if len(got) != workers {
		t.Fatalf("expected %d keys after concurrent updates, got %d", workers, len(got))
	}
	for i := 0; i < workers; i++ {
		if _, ok := got[fmt.Sprintf("key-%03d", i)]; !ok {
			t.Fatalf("lost update for key-%03d", i)
		}
	}
}

func TestUpdateMap_UnchangedOrErroredMutationWritesNothing(t *testing.T) {
	s := newTempStore(t)
	if err := s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
		m["base"] = "on"
		return true, nil
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
		m["ignored"] = "x"
		return false, nil
	}); err != nil {
		t.Fatalf("unchanged mutation: %v", err)
	}
	wantErr := fmt.Errorf("refused")
	if err := s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
		m["ignored"] = "y"
		return true, wantErr
	}); err != wantErr {
		t.Fatalf("expected mutate error, got %v", err)
	}
	got, err := s.LoadMap("prefs")
	if err != nil {
		t.Fatalf("LoadMap: %v", err)
	}
	if len(got) != 1 || got["base"] != "on" {
		t.Fatalf("expected only base key, got %#v", got)
	}
}

func TestUpdateMap_FailedSaveLeavesCacheAndFileUnchanged(t *testing.T) {
	s := newTempStore(t)
	dir := config.Instance.GetUserDataPath()
	if err := s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
		m["keep"] = "yes"
		return true, nil
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// Warm the in-memory cache so the failing update would hit the cached value if it aliased it.
	if _, err := s.LoadMap("prefs"); err != nil {
		t.Fatalf("warm cache: %v", err)
	}

	// A regular file in place of a parent directory makes the save fail.
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatalf("write blocker: %v", err)
	}
	config.Instance.SetUserDataPath(filepath.Join(blocker, "data"))
	err := s.UpdateMap("prefs", func(m map[string]interface{}) (bool, error) {
		m["attempt"] = "no"
		return true, nil
	})
	config.Instance.SetUserDataPath(dir)
	if err == nil {
		t.Fatal("expected save failure, got nil")
	}

	got, err := s.LoadMap("prefs")
	if err != nil {
		t.Fatalf("LoadMap after failed save: %v", err)
	}
	if _, ok := got["attempt"]; ok {
		t.Fatalf("failed save leaked into cache: %#v", got)
	}
	if got["keep"] != "yes" || len(got) != 1 {
		t.Fatalf("expected only seeded key, got %#v", got)
	}
}
