package server

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/config"

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

func normalizeNowPlayingMetadata(title, artist, album string) (string, string, string) {
	trimmedTitle := strings.TrimSpace(title)
	if trimmedTitle == "" {
		trimmedTitle = "UX-Music"
	}
	return trimmedTitle, strings.TrimSpace(artist), strings.TrimSpace(album)
}

func resolveNowPlayingArtworkPath(raw string) string {
	source := strings.TrimSpace(raw)
	if source == "" {
		return ""
	}

	lowerSource := strings.ToLower(source)
	if strings.HasPrefix(lowerSource, "http://") ||
		strings.HasPrefix(lowerSource, "https://") ||
		strings.HasPrefix(lowerSource, "data:") ||
		strings.HasPrefix(lowerSource, "blob:") {
		return ""
	}

	source = strings.TrimPrefix(source, "safe-artwork://")
	source = strings.TrimPrefix(source, "/safe-artwork/")
	source = strings.TrimPrefix(source, "safe-artwork/")
	if decoded, err := url.PathUnescape(source); err == nil {
		source = decoded
	}
	source = strings.TrimSpace(source)
	if source == "" {
		return ""
	}

	if filepath.IsAbs(source) {
		if _, err := os.Stat(source); err == nil {
			return source
		}
		return ""
	}

	source = strings.TrimLeft(source, `/\`)
	cleanedRelative := filepath.Clean(source)
	if cleanedRelative == "." || cleanedRelative == ".." || strings.HasPrefix(cleanedRelative, ".."+string(filepath.Separator)) {
		return ""
	}

	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	fullPath := filepath.Join(artworksDir, cleanedRelative)
	cleanArtworksDir := filepath.Clean(artworksDir)
	cleanFullPath := filepath.Clean(fullPath)
	artworksPrefix := cleanArtworksDir + string(filepath.Separator)
	if cleanFullPath != cleanArtworksDir && !strings.HasPrefix(cleanFullPath, artworksPrefix) {
		return ""
	}
	if _, err := os.Stat(cleanFullPath); err != nil {
		return ""
	}
	return cleanFullPath
}

func (a *App) updateOSNowPlayingByPath(filePath string, playing bool) {
	a.mediaStateMu.Lock()
	title := strings.TrimSpace(a.mediaTitle)
	artist := strings.TrimSpace(a.mediaArtist)
	album := strings.TrimSpace(a.mediaAlbum)
	artworkPath := strings.TrimSpace(a.mediaArtwork)

	if title == "" {
		fileName := filepath.Base(strings.TrimSpace(filePath))
		title = strings.TrimSpace(strings.TrimSuffix(fileName, filepath.Ext(fileName)))
		if title == "" {
			title = "UX-Music"
		}
		a.mediaTitle = title
	}
	a.mediaStateMu.Unlock()

	setOSNowPlaying(title, artist, album, artworkPath, playing)
}

func (a *App) updateOSNowPlayingMetadata(title string, artist string, album string, artwork string, playing bool) {
	trimmedTitle, trimmedArtist, trimmedAlbum := normalizeNowPlayingMetadata(title, artist, album)
	resolvedArtworkPath := resolveNowPlayingArtworkPath(artwork)

	a.mediaStateMu.Lock()
	a.mediaTitle = trimmedTitle
	a.mediaArtist = trimmedArtist
	a.mediaAlbum = trimmedAlbum
	a.mediaArtwork = resolvedArtworkPath
	a.mediaStateMu.Unlock()

	setOSNowPlaying(trimmedTitle, trimmedArtist, trimmedAlbum, resolvedArtworkPath, playing)
}

func (a *App) updateOSPlaybackState(playing bool) {
	a.mediaStateMu.Lock()
	title := a.mediaTitle
	artist := a.mediaArtist
	album := a.mediaAlbum
	artworkPath := a.mediaArtwork
	a.mediaStateMu.Unlock()

	normalizedTitle, normalizedArtist, normalizedAlbum := normalizeNowPlayingMetadata(title, artist, album)
	setOSNowPlaying(normalizedTitle, normalizedArtist, normalizedAlbum, artworkPath, playing)
}

func (a *App) clearOSNowPlayingState() {
	a.mediaStateMu.Lock()
	a.mediaTitle = ""
	a.mediaArtist = ""
	a.mediaAlbum = ""
	a.mediaArtwork = ""
	a.mediaStateMu.Unlock()

	clearOSNowPlaying()
}
