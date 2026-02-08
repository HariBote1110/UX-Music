package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/scanner"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/audio"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// ScanLibrary calls the existing ScanLibrary logic
func (a *App) ScanLibrary(paths []string) scanner.ScanResult {
	fmt.Printf("[Wails] Scanning library: %v\n", paths)
	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	scanResult := scanner.ScanLibrary(paths, artworksDir)

	// Merge newly scanned songs into persisted library (dedupe by path).
	existingRaw, _ := store.Instance.Load("library")
	existingSongs := []interface{}{}
	existingPaths := map[string]struct{}{}

	if arr, ok := existingRaw.([]interface{}); ok {
		existingSongs = arr
		for _, item := range arr {
			if m, ok := item.(map[string]interface{}); ok {
				if p, ok := m["path"].(string); ok && p != "" {
					existingPaths[p] = struct{}{}
				}
			}
		}
	}

	newSongs := make([]scanner.Song, 0, len(scanResult.Songs))
	for _, song := range scanResult.Songs {
		if song.Path == "" {
			continue
		}
		if _, exists := existingPaths[song.Path]; exists {
			continue
		}
		existingPaths[song.Path] = struct{}{}
		existingSongs = append(existingSongs, song)
		newSongs = append(newSongs, song)
	}

	_ = store.Instance.Save("library", existingSongs)
	wailsRuntime.EventsEmit(a.ctx, "scan-complete", newSongs)

	go a.BuildFLACIndexes()

	scanResult.Songs = newSongs
	scanResult.Count = len(newSongs)
	return scanResult
}

// BuildFLACIndexes iterates through the library and pre-generates indexes for all FLAC files
func (a *App) BuildFLACIndexes() {
	fmt.Println("[Wails] BuildFLACIndexes started")
	data, _ := store.Instance.Load("library")
	if data == nil {
		return
	}

	songs := data.([]interface{})
	var flacPaths []string
	for _, s := range songs {
		song := s.(map[string]interface{})
		path, ok := song["path"].(string)
		if ok && strings.HasSuffix(strings.ToLower(path), ".flac") {
			flacPaths = append(flacPaths, path)
		}
	}

	total := len(flacPaths)
	if total == 0 {
		return
	}
	fmt.Printf("[Wails] Found %d FLAC files to index\n", total)

	go func() {
		numWorkers := runtime.NumCPU()
		if numWorkers > 4 {
			numWorkers = 4
		}

		type job struct {
			index int
			path  string
		}
		jobs := make(chan job, total)
		var wg sync.WaitGroup

		var completed atomic.Int32

		for w := 0; w < numWorkers; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for j := range jobs {
					if err := audio.BuildFLACIndex(j.path); err != nil {
						fmt.Printf("[Audio] Error indexing %s: %v\n", j.path, err)
					}
					c := completed.Add(1)
					wailsRuntime.EventsEmit(a.ctx, "flac-index-progress", map[string]interface{}{
						"current": int(c),
						"total":   total,
						"path":    filepath.Base(j.path),
					})
				}
			}()
		}

		for i, path := range flacPaths {
			jobs <- job{index: i, path: path}
		}
		close(jobs)

		wg.Wait()
		wailsRuntime.EventsEmit(a.ctx, "flac-index-complete", total)
		fmt.Println("[Wails] BuildFLACIndexes completed")
	}()
}
