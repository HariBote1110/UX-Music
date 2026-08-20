package server

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/config"
)

func (a *App) initOSMediaControls() {
	err := registerOSMediaCommands(a.dispatchOSMediaCommand)
	if err != nil {
		println("[OSMedia] initialization failed:", err.Error())
	}
}

// initAppVisibilityObserver wires the NSApplicationDidHide/DidUnhide
// observer (app_visibility_darwin.go/.m; a no-op on non-darwin, see
// app_visibility_stub.go) to handleAppVisibilityChanged, for the renderer's
// park.ts (Phase 2/3 of markdown/background-native-queue-plan.md). GUI-mode
// only — like initOSMediaControls/initTray, this is only ever called from
// Startup, which itself is only invoked via Wails' OnStartup (see main.go);
// headless `--serve` never runs it.
func (a *App) initAppVisibilityObserver() {
	registerAppVisibilityObserver(a.handleAppVisibilityChanged)
}

// handleAppVisibilityChanged is initAppVisibilityObserver's callback body,
// factored out so it is unit-testable without the platform-specific
// registerAppVisibilityObserver binding (same pattern as
// dispatchOSMediaCommand below). It always emits "app-visibility-changed"
// for park.ts's debounce timer, and — Phase 3's un-park trigger — when the
// window is shown again (hidden=false) while the SPA is parked, reloads the
// (destroyed) webview directly: no JS is alive while parked to react to an
// event on its own, so Go must initiate the reload itself.
func (a *App) handleAppVisibilityChanged(hidden bool) {
	a.emit("app-visibility-changed", map[string]interface{}{"hidden": hidden})
	if !hidden {
		a.reloadWebViewIfParked()
	}
}

// dispatchOSMediaCommand handles one OS media-key command ("play", "pause",
// "toggle", "next", "previous", "stop" — see renderer.ts's os-media-command
// listener for the full set the renderer itself still handles). Factored
// out of initOSMediaControls so it can be unit tested without the
// platform-specific registerOSMediaCommands binding.
func (a *App) dispatchOSMediaCommand(command string) {
	if a.ctx == nil {
		return
	}
	// While the Go queue is active (something has called QueueSet — see
	// app_queue.go), next/previous are handled entirely in Go instead of
	// being forwarded to the renderer's playNextSong/playPrevSong, which has
	// no queue of its own to advance in that mode.
	if a.ensureQueue().Active() {
		switch command {
		case "next":
			_ = a.QueueNext()
			return
		case "previous":
			_ = a.QueuePrev()
			return
		}
	}
	a.emit("os-media-command", command)
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

func ResolveArtworkPath(raw string) string {
	return resolveNowPlayingArtworkPath(raw)
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
	setTrayPlayPauseLabel(trayPlayPauseLabel(playing))
}

func (a *App) clearOSNowPlayingState() {
	a.mediaStateMu.Lock()
	a.mediaTitle = ""
	a.mediaArtist = ""
	a.mediaAlbum = ""
	a.mediaArtwork = ""
	a.mediaSongID = ""
	a.mediaArtworkID = ""
	a.mediaStateMu.Unlock()

	clearOSNowPlaying()
}
