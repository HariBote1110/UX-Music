package main

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx context.Context
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
}

// Ping returns a pong message
func (a *App) Ping() string {
	return "pong from Wails!"
}

// ScanLibrary calls the existing ScanLibrary logic
func (a *App) ScanLibrary(paths []string) ScanResult {
	fmt.Printf("[Wails] Scanning library: %v\n", paths)
	return ScanLibrary(paths)
}

// GetYouTubeInfo calls the existing GetYouTubeVideoInfo logic
func (a *App) GetYouTubeInfo(url string) (interface{}, error) {
	return GetYouTubeVideoInfo(url)
}

// GetSettings loads settings from settings.json
func (a *App) GetSettings() (interface{}, error) {
	fmt.Println("[Wails] GetSettings called")
	data, err := stores.Load("settings")
	if err != nil {
		return nil, err
	}
	if data == nil {
		return make(map[string]interface{}), nil
	}
	return data, nil
}

// SaveSettings saves settings to settings.json
func (a *App) SaveSettings(settings interface{}) error {
	fmt.Printf("[Wails] SaveSettings called: %v\n", settings)
	return stores.Save("settings", settings)
}

// GetArtworksDir returns the path to the artworks directory
func (a *App) GetArtworksDir() string {
	return filepath.Join(config.GetUserDataPath(), "Artworks")
}

// LoadLibrary loads the library and emits an event
func (a *App) LoadLibrary() {
	fmt.Println("[Wails] LoadLibrary current")
	songs, _ := stores.Load("library")
	albums, _ := stores.Load("albums")

	if songs == nil {
		songs = []interface{}{}
	}
	if albums == nil {
		albums = make(map[string]interface{})
	}

	data := map[string]interface{}{
		"songs":  songs,
		"albums": albums,
	}
	runtime.EventsEmit(a.ctx, "load-library", data)
}

// RequestInitialLibrary is a helper for initial load
func (a *App) RequestInitialLibrary() {
	a.LoadLibrary()
}

// LoadPlayCounts loads play counts and emits an event
func (a *App) LoadPlayCounts() {
	counts, _ := stores.Load("play-counts")
	if counts == nil {
		counts = make(map[string]interface{})
	}
	runtime.EventsEmit(a.ctx, "play-counts-updated", counts)
}
