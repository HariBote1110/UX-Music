package audioembed

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"
)

func makeOrthogonalVector(idx int) []float32 {
	v := make([]float32, EmbedDim)
	if idx >= 0 && idx < EmbedDim {
		v[idx] = 1.0
	}
	return v
}

func TestCosineSimilarity_BasicCases(t *testing.T) {
	a := makeOrthogonalVector(0)
	b := makeOrthogonalVector(0)
	c := makeOrthogonalVector(1)
	if got := cosineSimilarity(a, b); math.Abs(float64(got-1.0)) > 1e-6 {
		t.Errorf("identical vectors: expected 1.0, got %f", got)
	}
	if got := cosineSimilarity(a, c); math.Abs(float64(got)) > 1e-6 {
		t.Errorf("orthogonal vectors: expected 0.0, got %f", got)
	}
}

func TestSearchByVector_RanksByCosine(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	// Three tracks placed along different axes.
	_ = store.Put("track-a", Embedding{Vector: makeOrthogonalVector(0), Version: "v1", AnalysedAt: time.Now()})
	_ = store.Put("track-b", Embedding{Vector: makeOrthogonalVector(1), Version: "v1", AnalysedAt: time.Now()})
	_ = store.Put("track-c", Embedding{Vector: makeOrthogonalVector(2), Version: "v1", AnalysedAt: time.Now()})

	query := makeOrthogonalVector(0) // should match track-a perfectly
	hits, err := SearchByVector(store, query, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 3 {
		t.Fatalf("expected 3 hits, got %d", len(hits))
	}
	if hits[0].TrackID != "track-a" {
		t.Errorf("expected track-a first, got %s", hits[0].TrackID)
	}
	if hits[0].Score < hits[1].Score || hits[1].Score < hits[2].Score {
		t.Errorf("hits not sorted desc by score: %+v", hits)
	}
}

func TestSearchByVector_RespectsTopK(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	for i := 0; i < 10; i++ {
		_ = store.Put(string(rune('a'+i)), Embedding{Vector: makeOrthogonalVector(i), Version: "v1", AnalysedAt: time.Now()})
	}
	hits, _ := SearchByVector(store, makeOrthogonalVector(0), 3)
	if len(hits) != 3 {
		t.Fatalf("expected top-3, got %d", len(hits))
	}
}

func TestSearchByVector_EmptyStoreReturnsEmpty(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	hits, err := SearchByVector(store, makeOrthogonalVector(0), 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 0 {
		t.Fatalf("expected empty, got %d", len(hits))
	}
}

func TestSearchByVector_RejectsWrongDim(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	_, err := SearchByVector(store, []float32{0.1, 0.2}, 5)
	if err == nil {
		t.Fatal("expected dim mismatch error")
	}
}

func TestSearchText_UsesSidecarForQuery(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	_ = store.Put("track-x", Embedding{Vector: makeOrthogonalVector(7), Version: "v1", AnalysedAt: time.Now()})

	runner := &stubRunner{respond: func(req Request) (Result, error) {
		if len(req.Texts) != 1 || req.Texts[0] != "夜ドライブ" {
			t.Errorf("unexpected sidecar request: %+v", req)
		}
		return Result{
			Success: true, Version: "v1",
			TextEmbeddings: []SidecarTextEmbedding{
				{Text: req.Texts[0], Vector: makeOrthogonalVector(7), Dim: EmbedDim},
			},
		}, nil
	}}
	hits, err := SearchText(context.Background(), "夜ドライブ", store, runner.run, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].TrackID != "track-x" {
		t.Fatalf("unexpected hits: %+v", hits)
	}
}

func TestSearchText_PropagatesSidecarFailure(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	runner := &stubRunner{respond: func(Request) (Result, error) { return Result{}, errors.New("nope") }}
	_, err := SearchText(context.Background(), "any", store, runner.run, 3)
	if err == nil {
		t.Fatal("expected error")
	}
}
