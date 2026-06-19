package audioembed

import (
	"context"
	"fmt"
	"time"
)

// SidecarRunner is the function signature used to run one sidecar request.
// Production wires this to RunSidecar (closure capturing argv/env/progress);
// tests substitute a stub.
type SidecarRunner func(ctx context.Context, req Request) (Result, error)

// AnalyseStats is the summary returned by AnalyseSongs.
type AnalyseStats struct {
	Considered int // total paths inspected
	Skipped    int // already at currentVersion
	Analysed   int // newly stored this run
	Failed     int // sidecar errors per path
}

// AnalyseOptions tunes batch processing.
type AnalyseOptions struct {
	BatchSize  int // ≤0 → default 16
	OnProgress func(done, total int)
}

const defaultBatchSize = 16

// AnalyseSongs walks paths, batches the ones whose stored embedding is
// missing or at a different version, and writes fresh embeddings via runner.
// Up-to-date entries are skipped.
//
// Errors from individual batches do not abort the whole run unless runner
// returns a Go-level error (e.g. the sidecar process itself failed to spawn);
// per-batch sidecar-reported errors are counted in stats.Failed.
func AnalyseSongs(
	ctx context.Context,
	paths []string,
	currentVersion string,
	store *Store,
	runner SidecarRunner,
	opts AnalyseOptions,
) (AnalyseStats, error) {
	stats := AnalyseStats{Considered: len(paths)}
	if len(paths) == 0 {
		if opts.OnProgress != nil {
			opts.OnProgress(0, 0)
		}
		return stats, nil
	}

	needs := make([]string, 0, len(paths))
	for _, p := range paths {
		if store.Needs(p, currentVersion) {
			needs = append(needs, p)
		} else {
			stats.Skipped++
		}
	}

	batchSize := opts.BatchSize
	if batchSize <= 0 {
		batchSize = defaultBatchSize
	}

	totalToDo := len(needs)
	done := 0
	if opts.OnProgress != nil {
		opts.OnProgress(done, totalToDo)
	}

	for start := 0; start < totalToDo; start += batchSize {
		end := start + batchSize
		if end > totalToDo {
			end = totalToDo
		}
		batch := needs[start:end]

		result, err := runner(ctx, Request{SongPaths: batch})
		if err != nil {
			return stats, fmt.Errorf("audioembed: sidecar runner: %w", err)
		}
		if !result.Success {
			stats.Failed += len(batch)
		} else {
			version := result.Version
			if version == "" {
				version = currentVersion
			}
			ts := time.Now().UTC()
			byPath := make(map[string]SidecarEmbedding, len(result.Embeddings))
			for _, e := range result.Embeddings {
				byPath[e.SongPath] = e
			}
			for _, p := range batch {
				e, ok := byPath[p]
				if !ok || len(e.Vector) != EmbedDim {
					stats.Failed++
					continue
				}
				if err := store.Put(p, Embedding{
					Vector:     e.Vector,
					Version:    version,
					AnalysedAt: ts,
				}); err != nil {
					stats.Failed++
					continue
				}
				stats.Analysed++
			}
		}

		done += len(batch)
		if opts.OnProgress != nil {
			opts.OnProgress(done, totalToDo)
		}
		if err := ctx.Err(); err != nil {
			return stats, err
		}
	}

	return stats, nil
}
