package main

import (
	"context"
	"fmt"
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
