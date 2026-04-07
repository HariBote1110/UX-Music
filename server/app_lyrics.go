package server

import (
	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/lyricssync"

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

// AutoSyncLyrics performs automatic lyric timestamp alignment
func (a *App) AutoSyncLyrics(req lyricssync.Request) (lyricssync.Result, error) {
	if a.lyricsSyncer == nil {
		a.lyricsSyncer = lyricssync.NewSyncer()
	}
	return a.lyricsSyncer.Sync(req), nil
}
