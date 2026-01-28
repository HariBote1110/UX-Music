package main

import (
	"context"
	"sync"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/pkg/audio"
	"ux-music-sidecar/pkg/cdrip"
	"ux-music-sidecar/pkg/mtp"
	"ux-music-sidecar/pkg/normalize"
)

// App struct
type App struct {
	ctx          context.Context
	ripper       *cdrip.Ripper
	mtpManager   *mtp.Manager
	normalizer   *normalize.Normalizer
	audioPlayer  *audio.Player
	mtpConnected bool
	mtpMu        sync.Mutex
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{
		ripper:     cdrip.NewRipper("", config.FFmpegPath, config.GetUserDataPath()),
		mtpManager: mtp.NewManager(),
		normalizer: normalize.NewNormalizer(config.FFmpegPath, config.FFprobePath),
	}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Initialize Audio Player
	player, err := audio.NewPlayer()
	if err != nil {
		println("Error initializing audio player:", err.Error())
	}
	a.audioPlayer = player

	// Start MTP device monitor
	a.startMTPMonitor()
}

// Ping returns a pong message
func (a *App) Ping() string {
	return "pong"
}
