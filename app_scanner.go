package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/scanner"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/audio"

	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// ScanLibrary calls the existing ScanLibrary logic
func (a *App) ScanLibrary(paths []string) scanner.ScanResult {
	fmt.Printf("[Wails] Scanning library: %v\n", paths)
	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	libraryPath, err := a.getOrPromptLibraryPath()
	if err != nil {
		fmt.Printf("[Wails] Failed to prepare library path: %v\n", err)
		scanResult := scanner.ScanResult{Songs: []scanner.Song{}, Count: 0, Time: 0}
		wailsRuntime.EventsEmit(a.ctx, "scan-complete", scanResult.Songs)
		return scanResult
	}
	if libraryPath == "" {
		fmt.Println("[Wails] Library path selection cancelled")
		scanResult := scanner.ScanResult{Songs: []scanner.Song{}, Count: 0, Time: 0}
		wailsRuntime.EventsEmit(a.ctx, "scan-complete", scanResult.Songs)
		return scanResult
	}

	scanResult := scanner.ScanLibrary(paths, artworksDir)
	importedSongs := importSongsToLibrary(scanResult.Songs, libraryPath)
	scanResult.Songs = importedSongs
	scanResult.Count = len(importedSongs)

	// Merge newly scanned songs into persisted library (dedupe by path).
	existingRaw, _ := store.Instance.Load("library")
	existingSongs := []interface{}{}
	existingPathIndex := map[string]int{}

	if arr, ok := existingRaw.([]interface{}); ok {
		existingSongs = arr
		for i, item := range arr {
			if m, ok := item.(map[string]interface{}); ok {
				if p, ok := m["path"].(string); ok && p != "" {
					existingPathIndex[p] = i
				}
			}
		}
	}

	newSongs := make([]scanner.Song, 0, len(scanResult.Songs))
	for _, song := range scanResult.Songs {
		if song.Path == "" {
			continue
		}
		if idx, exists := existingPathIndex[song.Path]; exists {
			if existingMap, ok := existingSongs[idx].(map[string]interface{}); ok {
				mergeScannedSong(existingMap, song)
			}
			continue
		}
		existingPathIndex[song.Path] = len(existingSongs)
		existingSongs = append(existingSongs, song)
		newSongs = append(newSongs, song)
	}

	_ = store.Instance.Save("library", existingSongs)
	wailsRuntime.EventsEmit(a.ctx, "scan-complete", newSongs)
	a.queueLoudnessAnalysis(extractSongPaths(newSongs))

	go a.BuildFLACIndexes()

	scanResult.Songs = newSongs
	scanResult.Count = len(newSongs)
	return scanResult
}

func loadSettingsMap() map[string]interface{} {
	settingsRaw, _ := store.Instance.Load("settings")
	if settings, ok := settingsRaw.(map[string]interface{}); ok {
		return settings
	}
	return map[string]interface{}{}
}

func (a *App) getOrPromptLibraryPath() (string, error) {
	settings := loadSettingsMap()
	libraryPath, _ := settings["libraryPath"].(string)
	libraryPath = strings.TrimSpace(libraryPath)
	if libraryPath != "" {
		return libraryPath, nil
	}

	selectedPath, err := wailsRuntime.OpenDirectoryDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "ライブラリとして使用するフォルダを選択してください",
	})
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(selectedPath) == "" {
		return "", nil
	}

	settings["libraryPath"] = selectedPath
	if err := store.Instance.Save("settings", settings); err != nil {
		return "", err
	}
	wailsRuntime.EventsEmit(a.ctx, "settings-loaded", settings)
	return selectedPath, nil
}

func (a *App) SetLibraryPath() (string, error) {
	selectedPath, err := wailsRuntime.OpenDirectoryDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "ライブラリフォルダを選択してください",
	})
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(selectedPath) == "" {
		return "", nil
	}

	settings := loadSettingsMap()
	settings["libraryPath"] = selectedPath
	if err := store.Instance.Save("settings", settings); err != nil {
		return "", err
	}

	wailsRuntime.EventsEmit(a.ctx, "settings-loaded", settings)
	wailsRuntime.EventsEmit(a.ctx, "show-notification", "ライブラリフォルダを設定しました。")
	return selectedPath, nil
}

func importSongsToLibrary(songs []scanner.Song, libraryPath string) []scanner.Song {
	imported := make([]scanner.Song, 0, len(songs))
	seenDestinations := make(map[string]struct{}, len(songs))

	for _, song := range songs {
		if song.Path == "" {
			continue
		}

		artistDir := sanitiseFileName(song.AlbumArtist)
		if artistDir == "_" {
			artistDir = sanitiseFileName(song.Artist)
		}
		if artistDir == "_" {
			artistDir = "Unknown Artist"
		}

		albumDir := sanitiseFileName(song.Album)
		if albumDir == "_" {
			albumDir = "Unknown Album"
		}

		fileName := sanitiseFileName(filepath.Base(song.Path))
		destDir := filepath.Join(libraryPath, artistDir, albumDir)
		destPath := filepath.Join(destDir, fileName)

		if _, exists := seenDestinations[destPath]; exists {
			continue
		}
		seenDestinations[destPath] = struct{}{}

		if !samePath(song.Path, destPath) {
			if err := os.MkdirAll(destDir, 0755); err != nil {
				fmt.Printf("[Import] Failed to create directory %s: %v\n", destDir, err)
				continue
			}
			if _, err := os.Stat(destPath); os.IsNotExist(err) {
				if err := copyFile(song.Path, destPath); err != nil {
					fmt.Printf("[Import] Failed to copy %s -> %s: %v\n", song.Path, destPath, err)
					continue
				}
			}
		}

		song.Path = destPath
		song.ID = uuid.NewString()
		if info, statErr := os.Stat(destPath); statErr == nil {
			song.FileSize = info.Size()
		}
		imported = append(imported, song)
	}

	return imported
}

func sanitiseFileName(name string) string {
	if strings.TrimSpace(name) == "" {
		return "_"
	}
	replacer := strings.NewReplacer(
		"\\", "_",
		"/", "_",
		":", "_",
		"*", "_",
		"?", "_",
		"\"", "_",
		"<", "_",
		">", "_",
		"|", "_",
	)
	sanitised := replacer.Replace(name)
	sanitised = strings.TrimRight(sanitised, ". ")
	if sanitised == "" {
		return "_"
	}
	return sanitised
}

func samePath(aPath, bPath string) bool {
	aAbs, aErr := filepath.Abs(aPath)
	bAbs, bErr := filepath.Abs(bPath)
	if aErr != nil || bErr != nil {
		return filepath.Clean(aPath) == filepath.Clean(bPath)
	}
	return filepath.Clean(aAbs) == filepath.Clean(bAbs)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}

	_, err = io.Copy(out, in)
	closeErr := out.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return nil
}

func mergeScannedSong(existing map[string]interface{}, scanned scanner.Song) {
	updateString := func(key, value string, prefer bool) {
		if value == "" {
			return
		}
		current, _ := existing[key].(string)
		if prefer || current == "" || current == "Unknown Artist" || current == "Unknown Album" {
			existing[key] = value
		}
	}
	updateInt := func(key string, value int) {
		if value <= 0 {
			return
		}
		current, _ := existing[key].(float64)
		if current <= 0 {
			existing[key] = value
		}
	}
	updateFloat := func(key string, value float64) {
		if value <= 0 {
			return
		}
		current, _ := existing[key].(float64)
		if current <= 0 {
			existing[key] = value
		}
	}

	baseName := filepath.Base(scanned.Path)
	currentTitle, _ := existing["title"].(string)
	preferTitle := currentTitle == "" || currentTitle == baseName

	updateString("id", firstNonEmpty(scanned.ID, scanned.Path), false)
	updateString("title", scanned.Title, preferTitle)
	updateString("artist", scanned.Artist, false)
	updateString("album", scanned.Album, false)
	updateString("albumartist", scanned.AlbumArtist, false)
	updateString("genre", scanned.Genre, false)
	updateString("fileType", scanned.FileType, false)

	updateInt("year", scanned.Year)
	updateInt("trackNumber", scanned.TrackNumber)
	updateInt("discNumber", scanned.DiscNumber)
	updateInt("sampleRate", scanned.SampleRate)
	updateFloat("duration", scanned.Duration)

	if scanned.FileSize > 0 {
		current, _ := existing["fileSize"].(float64)
		if current <= 0 {
			existing["fileSize"] = scanned.FileSize
		}
	}

	if scanned.Artwork != nil {
		if _, exists := existing["artwork"]; !exists || existing["artwork"] == nil {
			existing["artwork"] = scanned.Artwork
		}
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func extractSongPaths(songs []scanner.Song) []string {
	paths := make([]string, 0, len(songs))
	for _, song := range songs {
		if strings.TrimSpace(song.Path) != "" {
			paths = append(paths, song.Path)
		}
	}
	return paths
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
