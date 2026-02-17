package main

import (
	"path/filepath"
	"strings"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

func (a *App) initOSMediaControls() {
	err := registerOSMediaCommands(func(command string) {
		if a.ctx == nil {
			return
		}
		wailsRuntime.EventsEmit(a.ctx, "os-media-command", command)
	})
	if err != nil {
		println("[OSMedia] initialization failed:", err.Error())
	}
}

func (a *App) updateOSNowPlayingByPath(filePath string, playing bool) {
	fileName := filepath.Base(strings.TrimSpace(filePath))
	title := strings.TrimSpace(strings.TrimSuffix(fileName, filepath.Ext(fileName)))
	if title == "" {
		title = "UX-Music"
	}
	a.updateOSNowPlaying(title, "", "", playing)
}

func (a *App) updateOSNowPlaying(title string, artist string, album string, playing bool) {
	trimmedTitle := strings.TrimSpace(title)
	if trimmedTitle == "" {
		trimmedTitle = "UX-Music"
	}
	trimmedArtist := strings.TrimSpace(artist)
	trimmedAlbum := strings.TrimSpace(album)

	a.mediaStateMu.Lock()
	a.mediaTitle = trimmedTitle
	a.mediaArtist = trimmedArtist
	a.mediaAlbum = trimmedAlbum
	a.mediaStateMu.Unlock()

	setOSNowPlaying(trimmedTitle, trimmedArtist, trimmedAlbum, playing)
}

func (a *App) updateOSPlaybackState(playing bool) {
	a.mediaStateMu.Lock()
	title := a.mediaTitle
	artist := a.mediaArtist
	album := a.mediaAlbum
	a.mediaStateMu.Unlock()

	if strings.TrimSpace(title) == "" {
		title = "UX-Music"
	}
	setOSNowPlaying(title, artist, album, playing)
}

func (a *App) clearOSNowPlayingState() {
	a.mediaStateMu.Lock()
	a.mediaTitle = ""
	a.mediaArtist = ""
	a.mediaAlbum = ""
	a.mediaStateMu.Unlock()

	clearOSNowPlaying()
}
