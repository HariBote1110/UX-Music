package server

import (
	"encoding/json"
	"fmt"
	"sort"
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

func (a *App) CDSearchVocaDB(query string) ([]cdrip.ReleaseInfo, error) {
	return cdrip.SearchVocaDBByText(query)
}

func (a *App) CDApplyVocaDBMetadata(args map[string]interface{}) (*cdrip.ReleaseInfo, error) {
	tracksJSON, _ := json.Marshal(args["tracks"])
	var tracks []cdrip.Track
	json.Unmarshal(tracksJSON, &tracks)

	releaseID, _ := args["releaseId"].(string)

	return cdrip.ApplyVocaDBMetadata(tracks, releaseID)
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

	outputPaths, err := a.ripper.StartRip(tracks, options, libraryPath, progressChan)
	close(progressChan)

	if err != nil {
		fmt.Printf("[Wails] Rip error: %v\n", err)
		return nil, err
	}

	fmt.Printf("[Wails] Rip completed — %d files created\n", len(outputPaths))

	// 今回リップしたファイルのみをスキャンして重複を防ぐ
	artworksDir := config.GetUserDataPath() + "/Artworks"
	scanResult := scanner.ScanLibrary(outputPaths, artworksDir)

	existingSongs, _ := store.Instance.LoadSlice("library")
	existingPathIndex := map[string]int{}
	for i, item := range existingSongs {
		if m, ok := item.(map[string]interface{}); ok {
			if p, ok := m["path"].(string); ok && p != "" {
				existingPathIndex[p] = i
			}
		}
	}

	newSongs := make([]scanner.Song, 0, len(scanResult.Songs))
	for _, song := range scanResult.Songs {
		if song.Path == "" {
			continue
		}
		if idx, exists := existingPathIndex[song.Path]; exists {
			// 既存エントリを上書き更新（再リップ時はメタデータを最新に）
			if existingMap, ok := existingSongs[idx].(map[string]interface{}); ok {
				mergeScannedSong(existingMap, song)
			}
			continue
		}
		newSongs = append(newSongs, song)
	}

	// 並列スキャンによる不定順をディスク番号→トラック番号順に正規化してから永続化する
	sort.Slice(newSongs, func(i, j int) bool {
		di, dj := newSongs[i].DiscNumber, newSongs[j].DiscNumber
		if di != dj {
			return di < dj
		}
		return newSongs[i].TrackNumber < newSongs[j].TrackNumber
	})

	for _, song := range newSongs {
		existingPathIndex[song.Path] = len(existingSongs)
		existingSongs = append(existingSongs, song)
	}

	_ = store.Instance.Save("library", existingSongs)

	// cd-rip-complete イベントで通知（scan-complete と区別してビュー再描画を回避）
	wailsRuntime.EventsEmit(a.ctx, "cd-rip-complete", newSongs)
	a.queueLoudnessAnalysis(outputPaths)

	outputDir := a.ripper.OutputDir(libraryPath)
	return map[string]interface{}{
		"count":     len(outputPaths),
		"outputDir": outputDir,
	}, nil
}
