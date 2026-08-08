package server

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"ux-music-sidecar/internal/audioembed"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// CurrentAudioEmbedVersion is the version tag the analyser uses when checking
// whether a stored embedding is up to date. Bump this when the model or
// preprocessing changes meaningfully.
const CurrentAudioEmbedVersion = "audio-embed-v0-clap-music-audioset-htsat-tiny"

var (
	audioEmbedOnce  sync.Once
	audioEmbedStore *audioembed.Store
	audioEmbedErr   error
)

func getAudioEmbedStore() (*audioembed.Store, error) {
	audioEmbedOnce.Do(func() {
		audioEmbedStore, audioEmbedErr = audioembed.NewStore(config.GetUserDataPath())
	})
	return audioEmbedStore, audioEmbedErr
}

// AudioEmbedAnalyseResponse is what AnalyseLibraryAudioEmbeddings returns to JS.
type AudioEmbedAnalyseResponse struct {
	Considered int    `json:"considered"`
	Skipped    int    `json:"skipped"`
	Analysed   int    `json:"analysed"`
	Failed     int    `json:"failed"`
	Error      string `json:"error,omitempty"`
}

// AnalyseLibraryAudioEmbeddings walks the local library, embeds any tracks
// whose stored embedding is missing or stale, and saves them. Emits Wails
// events on `audio-embed-progress` with {done, total}.
//
// Blocks until done. Frontend should call from a goroutine / await.
func (a *App) AnalyseLibraryAudioEmbeddings() AudioEmbedAnalyseResponse {
	paths, err := collectLocalLibraryPaths()
	if err != nil {
		return AudioEmbedAnalyseResponse{Error: err.Error()}
	}
	embedStore, err := getAudioEmbedStore()
	if err != nil {
		return AudioEmbedAnalyseResponse{Error: fmt.Sprintf("open store: %v", err)}
	}
	argv, env, err := audioembed.ResolveDefault()
	if err != nil {
		return AudioEmbedAnalyseResponse{Error: fmt.Sprintf("resolve sidecar: %v", err)}
	}

	runner := func(ctx context.Context, req audioembed.Request) (audioembed.Result, error) {
		return audioembed.RunSidecar(ctx, req, argv, env, nil)
	}

	stats, runErr := audioembed.AnalyseSongs(
		a.ctx,
		paths,
		CurrentAudioEmbedVersion,
		embedStore,
		runner,
		audioembed.AnalyseOptions{
			BatchSize: 16,
			OnProgress: func(done, total int) {
				if a.ctx != nil {
					wailsRuntime.EventsEmit(a.ctx, "audio-embed-progress", map[string]int{
						"done": done, "total": total,
					})
				}
			},
		},
	)
	resp := AudioEmbedAnalyseResponse{
		Considered: stats.Considered,
		Skipped:    stats.Skipped,
		Analysed:   stats.Analysed,
		Failed:     stats.Failed,
	}
	if runErr != nil {
		resp.Error = runErr.Error()
	}
	return resp
}

// AudioEmbedSearchHit augments audioembed.SearchHit with the song path so the
// frontend can locate the track without an extra lookup.
type AudioEmbedSearchHit struct {
	TrackID string  `json:"trackId"` // == path
	Path    string  `json:"path"`
	Score   float32 `json:"score"`
}

// SearchTracksByMood embeds the query via the sidecar's text encoder and
// returns the top-K most similar tracks from the library.
func (a *App) SearchTracksByMood(query string, topK int) ([]AudioEmbedSearchHit, error) {
	if strings.TrimSpace(query) == "" {
		return nil, fmt.Errorf("query is empty")
	}
	if topK <= 0 {
		topK = 20
	}
	embedStore, err := getAudioEmbedStore()
	if err != nil {
		return nil, fmt.Errorf("open store: %w", err)
	}
	argv, env, err := audioembed.ResolveDefault()
	if err != nil {
		return nil, fmt.Errorf("resolve sidecar: %w", err)
	}
	runner := func(ctx context.Context, req audioembed.Request) (audioembed.Result, error) {
		return audioembed.RunSidecar(ctx, req, argv, env, nil)
	}
	hits, err := audioembed.SearchText(a.ctx, query, embedStore, runner, topK)
	if err != nil {
		return nil, err
	}
	out := make([]AudioEmbedSearchHit, 0, len(hits))
	for _, h := range hits {
		out = append(out, AudioEmbedSearchHit{TrackID: h.TrackID, Path: h.TrackID, Score: h.Score})
	}
	return out, nil
}

// AudioEmbedStatus is a small read-only summary for the UI.
type AudioEmbedStatus struct {
	Stored  int    `json:"stored"`
	Version string `json:"version"`
	Error   string `json:"error,omitempty"`
}

// GetAudioEmbedStatus returns how many embeddings are stored and the active version.
func (a *App) GetAudioEmbedStatus() AudioEmbedStatus {
	embedStore, err := getAudioEmbedStore()
	if err != nil {
		return AudioEmbedStatus{Error: err.Error(), Version: CurrentAudioEmbedVersion}
	}
	return AudioEmbedStatus{
		Stored:  embedStore.Count(),
		Version: CurrentAudioEmbedVersion,
	}
}

// collectLocalLibraryPaths returns absolute paths of local library songs.
// Sync-only entries (no local file) are excluded.
func collectLocalLibraryPaths() ([]string, error) {
	songs, err := store.Instance.LoadSlice("library")
	if err != nil {
		return nil, fmt.Errorf("load library: %w", err)
	}
	paths := make([]string, 0, len(songs))
	for _, item := range songs {
		songMap, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		path, _ := songMap["path"].(string)
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		paths = append(paths, path)
	}
	return paths, nil
}
