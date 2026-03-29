package main

import (
	"context"
	"fmt"
	"sync"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/lyricssync"
	"ux-music-sidecar/pkg/audio"
	"ux-music-sidecar/pkg/cdrip"
	"ux-music-sidecar/pkg/mtp"
	"ux-music-sidecar/pkg/normalize"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx               context.Context
	ripper            *cdrip.Ripper
	mtpManager        *mtp.Manager
	normalizer        *normalize.Normalizer
	loudnessMu        sync.Mutex
	audioPlayer       *audio.Player
	lyricsSyncer      *lyricssync.Syncer
	mtpConnected      bool
	mtpMu             sync.Mutex
	mediaStateMu      sync.Mutex
	mediaTitle        string
	mediaArtist       string
	mediaAlbum        string
	mediaArtwork      string
	deviceWatcherStop chan struct{}
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{
		ripper:       cdrip.NewRipper("", config.FFmpegPath, config.GetUserDataPath()),
		mtpManager:   mtp.NewManager(),
		normalizer:   normalize.NewNormalizer(config.FFmpegPath, config.FFprobePath),
		lyricsSyncer: lyricssync.NewSyncer(),
	}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Start the LAN HTTP server for Apple Watch / iPhone / Mobile companion
	StartWearServer(ctx, a)
	fmt.Printf("[Wear] Server address: %s\n", GetWearServerAddress())

	a.initOSMediaControls()

	// Initialize Audio Player
	player, err := audio.NewPlayer()
	if err != nil {
		println("Error initializing audio player:", err.Error())
	}
	a.audioPlayer = player

	if a.audioPlayer != nil {
		a.audioPlayer.SetOnFinished(func() {
			a.updateOSPlaybackState(false)
			if a.ctx != nil {
				wailsRuntime.EventsEmit(a.ctx, "audio-playback-finished")
			}
		})
	}

	// Start MTP device monitor
	a.startMTPMonitor()

	// Start audio device watcher (polls for Bluetooth/USB device changes)
	a.StartDeviceWatcher()
}

// Ping returns a pong message
func (a *App) Ping() string {
	return "pong"
}
