package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"ux-music-sidecar/internal/audioembed"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/llamasrv"
	"ux-music-sidecar/internal/moodspecial"
	"ux-music-sidecar/internal/store"
)

var (
	llamaSrvOnce sync.Once
	llamaSrv     *llamasrv.Server
	llamaSrvErr  error
)

// llamaServer returns the lazily-initialised llama-server wrapper.
// The actual process is not started until Start() is called.
func llamaServer() (*llamasrv.Server, error) {
	llamaSrvOnce.Do(func() {
		modelPath := envOrDefault("UX_MUSIC_GEMMA_MODEL", llamasrv.DefaultModelPath())
		if _, err := os.Stat(modelPath); err != nil {
			llamaSrvErr = fmt.Errorf(
				"Gemma モデル (%s) が見つかりません。\n"+
					"./scripts/smoke_gemma_llamacpp.sh の手順で取得してください",
				modelPath,
			)
			return
		}
		llamaSrv, llamaSrvErr = llamasrv.NewServer(llamasrv.Config{
			ModelPath: modelPath,
			LogPath:   envOrDefault("UX_MUSIC_GEMMA_LOG", ""),
		})
	})
	return llamaSrv, llamaSrvErr
}

// llmAdapter bridges llamasrv.Client (which exposes Chat(ctx, msg, ChatOptions))
// into moodspecial.LLMChat (which expects Chat(ctx, msg, ChatOpts)). The two option
// structs are intentionally separate so the packages stay independent.
type llmAdapter struct{ c *llamasrv.Client }

func (a llmAdapter) Chat(ctx context.Context, msg string, opts moodspecial.ChatOpts) (string, error) {
	return a.c.Chat(ctx, msg, llamasrv.ChatOptions{
		NPredict: opts.NPredict,
		Temp:     opts.Temp,
	})
}

// GenerateMoodSpecial creates a curated playlist feature for `mood`.
//
// Pipeline:
//  1. CLAP text-vs-audio search returns up to topK candidate tracks.
//  2. Library metadata is joined onto those tracks.
//  3. llama-server is started (on first call) and Gemma 4 E2B writes the
//     title/description/order/comments as structured JSON.
//  4. Refs in the JSON are mapped back to real track IDs.
//
// Blocking call. The first invocation pays ~10–20s of model load.
func (a *App) GenerateMoodSpecial(mood string, topK int) (moodspecial.Feature, error) {
	if topK <= 0 {
		topK = 20
	}

	// 1. CLAP candidate selection (reuses Phase 1 plumbing).
	hits, err := a.SearchTracksByMood(mood, topK)
	if err != nil {
		return moodspecial.Feature{}, fmt.Errorf("候補曲の検索に失敗: %w", err)
	}
	if len(hits) == 0 {
		return moodspecial.Feature{}, errors.New("候補曲が見つかりませんでした。先にライブラリを解析してください")
	}

	// 2. Join library metadata.
	meta := loadLibraryMetadataByPath()
	candidates := make([]moodspecial.Candidate, 0, len(hits))
	for _, h := range hits {
		c := moodspecial.Candidate{TrackID: h.TrackID}
		if m, ok := meta[h.TrackID]; ok {
			c.Title, _ = m["title"].(string)
			c.Artist, _ = m["artist"].(string)
			c.Album, _ = m["album"].(string)
		}
		candidates = append(candidates, c)
	}

	// 3. Start llama-server if needed.
	srv, err := llamaServer()
	if err != nil {
		return moodspecial.Feature{}, err
	}
	if err := srv.Start(a.ctx); err != nil {
		return moodspecial.Feature{}, fmt.Errorf("llama-server 起動に失敗: %w", err)
	}

	// 4. Build prompt, call LLM, parse, materialise.
	feat, err := moodspecial.Generate(a.ctx, mood, candidates, llmAdapter{c: srv.Client()})
	if err != nil {
		return moodspecial.Feature{}, fmt.Errorf("特集生成に失敗: %w", err)
	}
	return feat, nil
}

// StopGemmaServer terminates the background llama-server process.
// Safe to call when not running.
func (a *App) StopGemmaServer() error {
	if llamaSrv == nil {
		return nil
	}
	return llamaSrv.Stop()
}

// Shutdown is invoked by Wails when the app is closing. Used to terminate
// long-lived child processes (llama-server etc.).
func (a *App) Shutdown(ctx context.Context) {
	_ = ctx
	if llamaSrv != nil {
		_ = llamaSrv.Stop()
	}
}

// loadLibraryMetadataByPath builds a path→songMap index from the JSON library
// store, so we can attach Title/Artist/Album to CLAP search hits.
func loadLibraryMetadataByPath() map[string]map[string]interface{} {
	songs, err := store.Instance.LoadSlice("library")
	if err != nil {
		return nil
	}
	idx := make(map[string]map[string]interface{}, len(songs))
	for _, item := range songs {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		path, _ := m["path"].(string)
		if path == "" {
			continue
		}
		idx[path] = m
	}
	return idx
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Compile-time guard: keep the audioembed import live so refactors that drop
// SearchTracksByMood still flag it.
var _ = audioembed.EmbedDim

// Match config package name so the package compiles even when this file is
// the only consumer of these symbols.
var _ = config.GetUserDataPath
