package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

	libraryPath, _ := args["libraryPath"].(string)
	if libraryPath == "" {
		home, _ := os.UserHomeDir()
		libraryPath = filepath.Join(home, "Music")
	}

	fmt.Printf("[Wails] Starting rip of %d tracks to %s\n", len(tracks), libraryPath)

	progressChan := make(chan cdrip.RipProgress)

	go func() {
		for p := range progressChan {
			wailsRuntime.EventsEmit(a.ctx, "rip-progress", p)
		}
	}()

	err := a.ripper.StartRip(tracks, options, libraryPath, progressChan)
	close(progressChan)

	if err != nil {
		fmt.Printf("[Wails] Rip error: %v\n", err)
		return nil, err
	}

	fmt.Println("[Wails] Rip completed successfully")
	return map[string]interface{}{
		"count":     len(tracks),
		"outputDir": filepath.Join(libraryPath, "CD Rips"),
	}, nil
}
