package audioembed

import (
	"context"
	"fmt"
	"math"
	"sort"
)

// SearchHit is one ranked result of a similarity search.
type SearchHit struct {
	TrackID string  `json:"trackId"`
	Score   float32 `json:"score"`
}

// SearchByVector ranks every stored embedding by cosine similarity to query
// and returns the top-K hits (descending score). topK <= 0 returns all.
func SearchByVector(store *Store, query []float32, topK int) ([]SearchHit, error) {
	if len(query) != EmbedDim {
		return nil, fmt.Errorf("audioembed: query dim %d, want %d", len(query), EmbedDim)
	}
	hits := make([]SearchHit, 0, store.Count())
	err := store.Iterate(func(trackID string, e Embedding) bool {
		hits = append(hits, SearchHit{
			TrackID: trackID,
			Score:   cosineSimilarity(query, e.Vector),
		})
		return true
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].Score > hits[j].Score })
	if topK > 0 && len(hits) > topK {
		hits = hits[:topK]
	}
	return hits, nil
}

// SearchText embeds the query via the sidecar (text encoder) then ranks
// stored audio embeddings by cosine similarity.
func SearchText(
	ctx context.Context,
	query string,
	store *Store,
	runner SidecarRunner,
	topK int,
) ([]SearchHit, error) {
	if query == "" {
		return nil, fmt.Errorf("audioembed: empty query")
	}
	result, err := runner(ctx, Request{Texts: []string{query}})
	if err != nil {
		return nil, fmt.Errorf("audioembed: sidecar runner: %w", err)
	}
	if !result.Success {
		return nil, fmt.Errorf("audioembed: sidecar error: %s", result.Error)
	}
	if len(result.TextEmbeddings) == 0 {
		return nil, fmt.Errorf("audioembed: sidecar returned no text embeddings")
	}
	return SearchByVector(store, result.TextEmbeddings[0].Vector, topK)
}

func cosineSimilarity(a, b []float32) float32 {
	if len(a) != len(b) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		af := float64(a[i])
		bf := float64(b[i])
		dot += af * bf
		na += af * af
		nb += bf * bf
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return float32(dot / (math.Sqrt(na) * math.Sqrt(nb)))
}
