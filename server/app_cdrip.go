package server

import (
	"encoding/json"
	"fmt"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/scanner"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/cdrip"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

func (a *App) CDScan() ([]cdrip.Track, error) {
	return a.ripper.GetTrackList()
}

func (a *App) CDSearchTOC(tracks []cdrip.Track) ([]cdrip.ReleaseInfo, error) {
	return cdrip.SearchByTOC(tracks)
}

func (a *App) CDSearchText(query string) ([]cdrip.ReleaseInfo, error) {
	return cdrip.SearchByText(query)
}

func (a *App) CDApplyMetadata(args map[string]interface{}) (*cdrip.ReleaseInfo, error) {
	tracksJSON, _ := json.Marshal(args["tracks"])
	var tracks []cdrip.Track
	json.Unmarshal(tracksJSON, &tracks)

	releaseID, _ := args["releaseId"].(string)

	return cdrip.ApplyMetadata(tracks, releaseID)
}

func (a *App) CDStartRip(args map[string]interface{}) (interface{}, error) {
	fmt.Println("[Wails] CDStartRip called")
	tracksJSON, _ := json.Marshal(args["tracksToRip"])
	var tracks []cdrip.Track
	json.Unmarshal(tracksJSON, &tracks)

	optionsJSON, _ := json.Marshal(args["options"])
	var options cdrip.RipOptions
	json.Unmarshal(optionsJSON, &options)

	// 設定から cdRipMode を取得してバーストモードを反映
	if options.Mode == "" {
		settings := loadSettingsMap()
		if mode, _ := settings["cdRipMode"].(string); mode == "burst" {
			options.Mode = "burst"
		} else {
			options.Mode = "paranoia"
		}
	}

	// 設定からライブラリパスを取得（未設定ならフォルダ選択ダイアログ）
	libraryPath, err := a.getOrPromptLibraryPath()
	if err != nil || libraryPath == "" {
		return nil, fmt.Errorf("ライブラリパスが設定されていません")
	}

	fmt.Printf("[Wails] Starting rip of %d tracks to %s\n", len(tracks), libraryPath)

	progressChan := make(chan cdrip.RipProgress)
	go func() {
		for p := range progressChan {
			wailsRuntime.EventsEmit(a.ctx, "rip-progress", p)
		}
	}()

	err = a.ripper.StartRip(tracks, options, libraryPath, progressChan)
	close(progressChan)

	if err != nil {
		fmt.Printf("[Wails] Rip error: %v\n", err)
		return nil, err
	}

	fmt.Println("[Wails] Rip completed — scanning into library")

	// リップしたファイルをライブラリにスキャン・統合する
	outputDir := a.ripper.OutputDir(libraryPath)
	artworksDir := config.GetUserDataPath() + "/Artworks"
	scanResult := scanner.ScanLibrary([]string{outputDir}, artworksDir)

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

	// フロントエンドに新着曲を通知してライブラリ表示を更新
	wailsRuntime.EventsEmit(a.ctx, "scan-complete", newSongs)
	a.queueLoudnessAnalysis(extractSongPaths(newSongs))

	return map[string]interface{}{
		"count":     len(tracks),
		"outputDir": outputDir,
	}, nil
}
