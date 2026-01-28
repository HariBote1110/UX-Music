package main

import (
	"ux-music-sidecar/internal/lyrics"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// GetLyrics finds lyrics for a song
func (a *App) GetLyrics(fileName string) (interface{}, error) {
	return lyrics.FindLyrics(fileName)
}

// SaveLrcFile saves a lyrics file
func (a *App) SaveLrcFile(fileName string, content string) error {
	return lyrics.SaveLrcFile(fileName, content)
}

// HandleLyricsDrop handles dragging and dropping lyrics files
func (a *App) HandleLyricsDrop(paths []string) error {
	count, err := lyrics.CopyLyricsFiles(paths)
	if err == nil && count > 0 {
		wailsRuntime.EventsEmit(a.ctx, "lyrics-added-notification", count)
	}
	return err
}
