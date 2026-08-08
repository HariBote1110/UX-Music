package server

import (
	"context"
	"fmt"
	"sync"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/lyricssync"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/audio"
	"ux-music-sidecar/pkg/cdrip"
	"ux-music-sidecar/pkg/mtp"
	"ux-music-sidecar/pkg/normalize"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx               context.Context
	playCountsEmitter func(context.Context, string, interface{})
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
	playlist.SetSettingsProvider(store.Instance)
	lyricssync.SetSettingsProvider(store.Instance)

	return &App{
		playCountsEmitter: func(ctx context.Context, name string, data interface{}) {
			wailsRuntime.EventsEmit(ctx, name, data)
		},
		ripper:       cdrip.NewRipper("", config.FFmpegPath, config.GetUserDataPath()),
		mtpManager:   mtp.NewManager(),
		normalizer:   normalize.NewNormalizer(config.FFmpegPath, config.FFprobePath),
		lyricsSyncer: lyricssync.NewSyncer(),
	}
}

// Startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) Startup(ctx context.Context) {
	a.ctx = ctx

	a.bindLyricsSyncProgressEmitter()

	// Start the LAN HTTP server for Apple Watch / iPhone / Mobile companion
	StartLANServer(ctx, a)
	fmt.Printf("[LAN] Server address: %s\n", GetLANServerAddress())

	a.initOSMediaControls()

	// Initialize Audio Player
	audio.SetFFmpegPaths(config.FFmpegPath, config.FFprobePath)
	player, err := audio.NewPlayer()
	if err != nil {
		println("Error initializing audio player:", err.Error())
	}
	a.audioPlayer = player

	if a.audioPlayer != nil {
		a.audioPlayer.SetOnFinished(func() {
			a.updateOSPlaybackState(false)
			a.pushDiscordPresence(false)
			if a.ctx != nil {
				wailsRuntime.EventsEmit(a.ctx, "audio-playback-finished")
			}
		})
	}

	// Start MTP device monitor
	a.startMTPMonitor()

	// Start audio device watcher (polls for Bluetooth/USB device changes)
	a.StartDeviceWatcher()

	a.startSyncAutoLoop()
}

// Ping returns a pong message
func (a *App) Ping() string {
	return "pong"
}

// bindLyricsSyncProgressEmitter wires stderr-derived progress events to the frontend.
func (a *App) bindLyricsSyncProgressEmitter() {
	if a.lyricsSyncer == nil {
		return
	}
	a.lyricsSyncer.SetProgressHandler(func(stage string, percent float64) {
		if a.ctx == nil {
			return
		}
		wailsRuntime.EventsEmit(a.ctx, "lyrics-sync-progress", map[string]interface{}{
			"stage":   stage,
			"percent": percent,
		})
	})
}

// pushDiscordPresence updates Discord Rich Presence state.
func (a *App) pushDiscordPresence(_ bool) {}
