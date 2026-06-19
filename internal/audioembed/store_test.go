package audioembed

import (
	"math"
	"path/filepath"
	"testing"
	"time"
)

func makeVector(seed float32) []float32 {
	v := make([]float32, EmbedDim)
	for i := range v {
		v[i] = seed + float32(i)*0.001
	}
	return v
}

func vectorsEqual(a, b []float32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if math.Abs(float64(a[i]-b[i])) > 1e-6 {
			return false
		}
	}
	return true
}

func TestStore_EmptyReturnsNotFound(t *testing.T) {
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if _, ok, err := s.Get("track-1"); err != nil || ok {
		t.Fatalf("expected not found on empty store; ok=%v err=%v", ok, err)
	}
	if !s.Needs("track-1", "audio-embed-v0-clap") {
		t.Fatal("Needs should be true for missing track")
	}
	if s.Count() != 0 {
		t.Fatalf("expected Count=0, got %d", s.Count())
	}
}

func TestStore_PutThenGet(t *testing.T) {
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	want := Embedding{
		Vector:     makeVector(0.5),
		Version:    "audio-embed-v0-clap",
		AnalysedAt: time.Unix(1718700000, 0).UTC(),
	}
	if err := s.Put("track-1", want); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, ok, err := s.Get("track-1")
	if err != nil || !ok {
		t.Fatalf("Get: ok=%v err=%v", ok, err)
	}
	if !vectorsEqual(got.Vector, want.Vector) {
		t.Fatalf("vector mismatch")
	}
	if got.Version != want.Version {
		t.Fatalf("version mismatch: %q vs %q", got.Version, want.Version)
	}
	if !got.AnalysedAt.Equal(want.AnalysedAt) {
		t.Fatalf("AnalysedAt mismatch: %v vs %v", got.AnalysedAt, want.AnalysedAt)
	}
}

func TestStore_NeedsReflectsVersion(t *testing.T) {
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_ = s.Put("track-1", Embedding{Vector: makeVector(0.1), Version: "v1", AnalysedAt: time.Now().UTC()})
	if s.Needs("track-1", "v1") {
		t.Fatal("Needs should be false when version matches")
	}
	if !s.Needs("track-1", "v2") {
		t.Fatal("Needs should be true when version differs")
	}
	if !s.Needs("track-2", "v1") {
		t.Fatal("Needs should be true for unknown track")
	}
}

func TestStore_PutReplacesOnVersionChange(t *testing.T) {
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_ = s.Put("track-1", Embedding{Vector: makeVector(0.1), Version: "v1", AnalysedAt: time.Now().UTC()})
	newVec := makeVector(0.9)
	_ = s.Put("track-1", Embedding{Vector: newVec, Version: "v2", AnalysedAt: time.Now().UTC()})
	got, _, _ := s.Get("track-1")
	if got.Version != "v2" {
		t.Fatalf("expected v2, got %q", got.Version)
	}
	if !vectorsEqual(got.Vector, newVec) {
		t.Fatalf("vector not updated on replace")
	}
	if s.Count() != 1 {
		t.Fatalf("expected Count=1 after replace, got %d", s.Count())
	}
}

func TestStore_RejectWrongDim(t *testing.T) {
	s, _ := NewStore(t.TempDir())
	err := s.Put("track-1", Embedding{Vector: []float32{0.1, 0.2}, Version: "v1", AnalysedAt: time.Now()})
	if err == nil {
		t.Fatal("expected error for wrong-dim vector")
	}
}

func TestStore_Iterate(t *testing.T) {
	s, _ := NewStore(t.TempDir())
	_ = s.Put("a", Embedding{Vector: makeVector(0.1), Version: "v1", AnalysedAt: time.Now()})
	_ = s.Put("b", Embedding{Vector: makeVector(0.2), Version: "v1", AnalysedAt: time.Now()})
	_ = s.Put("c", Embedding{Vector: makeVector(0.3), Version: "v1", AnalysedAt: time.Now()})

	seen := map[string]bool{}
	err := s.Iterate(func(trackID string, e Embedding) bool {
		seen[trackID] = true
		if len(e.Vector) != EmbedDim {
			t.Errorf("iterated vector has wrong dim: %d", len(e.Vector))
		}
		return true
	})
	if err != nil {
		t.Fatalf("Iterate: %v", err)
	}
	if len(seen) != 3 || !seen["a"] || !seen["b"] || !seen["c"] {
		t.Fatalf("Iterate missing entries: %v", seen)
	}
}

func TestStore_IterateStopsOnFalse(t *testing.T) {
	s, _ := NewStore(t.TempDir())
	for _, id := range []string{"a", "b", "c"} {
		_ = s.Put(id, Embedding{Vector: makeVector(0.1), Version: "v1", AnalysedAt: time.Now()})
	}
	count := 0
	_ = s.Iterate(func(string, Embedding) bool {
		count++
		return false
	})
	if count != 1 {
		t.Fatalf("expected iterator to stop after first false; iterated %d times", count)
	}
}

func TestStore_PersistsAcrossReopen(t *testing.T) {
	dir := t.TempDir()
	{
		s, _ := NewStore(dir)
		_ = s.Put("track-1", Embedding{Vector: makeVector(0.7), Version: "v1", AnalysedAt: time.Unix(1718700000, 0).UTC()})
		_ = s.Put("track-2", Embedding{Vector: makeVector(0.2), Version: "v1", AnalysedAt: time.Unix(1718700001, 0).UTC()})
	}
	s2, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore reopen: %v", err)
	}
	if s2.Count() != 2 {
		t.Fatalf("expected Count=2 after reopen, got %d", s2.Count())
	}
	got, ok, err := s2.Get("track-1")
	if err != nil || !ok {
		t.Fatalf("Get after reopen: ok=%v err=%v", ok, err)
	}
	if !vectorsEqual(got.Vector, makeVector(0.7)) {
		t.Fatal("vector mismatch after reopen")
	}
}

func TestStore_IndexFileLocation(t *testing.T) {
	dir := t.TempDir()
	s, _ := NewStore(dir)
	_ = s.Put("track-1", Embedding{Vector: makeVector(0.1), Version: "v1", AnalysedAt: time.Now()})
	// Both files should be created under the supplied directory.
	for _, name := range []string{"audio_embeddings_index.json", "audio_embeddings.bin"} {
		path := filepath.Join(dir, name)
		if _, err := readFile(path); err != nil {
			t.Errorf("expected %s to exist: %v", name, err)
		}
	}
	_ = s
}
