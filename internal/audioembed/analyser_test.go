package audioembed

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// stubRunner records calls and replays canned results.
type stubRunner struct {
	calls    []Request
	respond  func(Request) (Result, error)
}

func (s *stubRunner) run(_ context.Context, req Request) (Result, error) {
	s.calls = append(s.calls, req)
	return s.respond(req)
}

func successAudioResult(req Request) (Result, error) {
	res := Result{Success: true, Version: "audio-embed-v0-clap"}
	for i, p := range req.SongPaths {
		vec := make([]float32, EmbedDim)
		vec[0] = float32(i) + 0.5
		res.Embeddings = append(res.Embeddings, SidecarEmbedding{SongPath: p, Vector: vec, Dim: EmbedDim})
	}
	return res, nil
}

func TestAnalyseSongs_SkipsUpToDateEntries(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	_ = store.Put("/a.mp3", Embedding{Vector: makeVector(0.1), Version: "audio-embed-v0-clap"})

	runner := &stubRunner{respond: successAudioResult}
	stats, err := AnalyseSongs(context.Background(), []string{"/a.mp3", "/b.mp3", "/c.mp3"},
		"audio-embed-v0-clap", store, runner.run, AnalyseOptions{BatchSize: 10})
	if err != nil {
		t.Fatalf("AnalyseSongs: %v", err)
	}
	if stats.Considered != 3 || stats.Skipped != 1 || stats.Analysed != 2 || stats.Failed != 0 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	// Runner should have been called only for the 2 needing paths.
	if len(runner.calls) != 1 {
		t.Fatalf("expected 1 batch call, got %d", len(runner.calls))
	}
	if len(runner.calls[0].SongPaths) != 2 {
		t.Fatalf("expected 2 paths in batch, got %d", len(runner.calls[0].SongPaths))
	}
}

func TestAnalyseSongs_ReanalysesOnVersionChange(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	_ = store.Put("/a.mp3", Embedding{Vector: makeVector(0.1), Version: "old-version"})

	// Stub echoes the version the analyser asked about by returning what the
	// real sidecar would: a fresh version tag. We use "audio-embed-v0-clap"
	// (per successAudioResult) as the canonical "current" tag.
	runner := &stubRunner{respond: successAudioResult}
	stats, err := AnalyseSongs(context.Background(), []string{"/a.mp3"},
		"audio-embed-v0-clap", store, runner.run, AnalyseOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Analysed != 1 || stats.Skipped != 0 {
		t.Fatalf("expected re-analysis, got stats: %+v", stats)
	}
	got, _, _ := store.Get("/a.mp3")
	if got.Version != "audio-embed-v0-clap" {
		t.Fatalf("version not updated: %q", got.Version)
	}
	// Vector should also have been overwritten (stub returns vec[0]==0.5).
	if got.Vector[0] != 0.5 {
		t.Fatalf("vector not refreshed: vec[0]=%f", got.Vector[0])
	}
}

func TestAnalyseSongs_BatchesAccordingToOptions(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	runner := &stubRunner{respond: successAudioResult}
	paths := []string{"/1", "/2", "/3", "/4", "/5"}
	_, err := AnalyseSongs(context.Background(), paths, "v1", store, runner.run, AnalyseOptions{BatchSize: 2})
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.calls) != 3 {
		t.Fatalf("expected 3 batch calls (2+2+1), got %d", len(runner.calls))
	}
	if store.Count() != 5 {
		t.Fatalf("expected 5 stored, got %d", store.Count())
	}
}

func TestAnalyseSongs_PropagatesBatchFailure(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	runner := &stubRunner{respond: func(req Request) (Result, error) {
		return Result{Success: false, Error: "sidecar boom"}, nil
	}}
	stats, _ := AnalyseSongs(context.Background(), []string{"/a", "/b"}, "v1", store, runner.run, AnalyseOptions{BatchSize: 10})
	if stats.Failed != 2 {
		t.Fatalf("expected 2 failed, got %+v", stats)
	}
	if store.Count() != 0 {
		t.Fatalf("nothing should be stored on failure")
	}
}

func TestAnalyseSongs_ReturnsRunnerError(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	runner := &stubRunner{respond: func(Request) (Result, error) { return Result{}, errors.New("network down") }}
	_, err := AnalyseSongs(context.Background(), []string{"/a"}, "v1", store, runner.run, AnalyseOptions{})
	if err == nil || !strings.Contains(err.Error(), "network down") {
		t.Fatalf("expected runner error to propagate, got: %v", err)
	}
}

func TestAnalyseSongs_EmitsProgress(t *testing.T) {
	store, _ := NewStore(t.TempDir())
	runner := &stubRunner{respond: successAudioResult}
	paths := []string{"/1", "/2", "/3", "/4"}
	var progresses []float64
	_, _ = AnalyseSongs(context.Background(), paths, "v1", store, runner.run, AnalyseOptions{
		BatchSize: 2,
		OnProgress: func(done, total int) {
			if total > 0 {
				progresses = append(progresses, float64(done)/float64(total))
			}
		},
	})
	if len(progresses) == 0 {
		t.Fatal("expected at least one progress callback")
	}
	if last := progresses[len(progresses)-1]; last < 0.99 {
		t.Fatalf("final progress should reach ~1.0, got %f", last)
	}
}
