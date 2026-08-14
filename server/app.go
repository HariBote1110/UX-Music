package server

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/lyricssync"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/audio"
	"ux-music-sidecar/pkg/cdrip"
	"ux-music-sidecar/pkg/mtp"
	"ux-music-sidecar/pkg/normalize"
)

// eventsEmitFunc is the process-wide event emission hook shared by every App
// instance and by package-level helpers that do not carry an *App (e.g.
// emitSyncTransferProgress). It defaults to a no-op so the server package
// stays headless-safe; app_wails_adapter.go's wireWailsRuntime rewires it to
// wailsRuntime.EventsEmit when running under the GUI.
var eventsEmitFunc = func(context.Context, string, interface{}) {}

// App struct
type App struct {
	ctx context.Context
	// playCountsEmitter is the injectable event emitter backing emit below.
	// The name predates its generalisation to all events (Phase 0-1); it is
	// kept so existing tests can inject a spy without depending on internals.
	playCountsEmitter func(context.Context, string, interface{})
	dialogs           DialogProvider
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
	// mediaSongID/mediaArtworkID mirror the currently playing song's library
	// ID and artwork hash (see artworkIDForRemoteSong), when the caller of
	// AudioSetNowPlayingMetadata supplies them. Surfaced as top-level
	// "songId"/"artworkId" in GET /v1/remote/state so mobile clients can
	// resolve lyrics/artwork by ID instead of fuzzy title matching.
	mediaSongID    string
	mediaArtworkID string
	deviceWatcherStop chan struct{}
	// bootedOutResidentAgent records whether Startup booted out a resident
	// `--serve` LaunchAgent to take over port 8765 (see performGUIHandoff in
	// app_handoff.go). When set, Shutdown re-bootstraps the agent so it
	// resumes its KeepAlive-managed run.
	bootedOutResidentAgent bool
	// remoteInitiatedNext marks that the *next* AudioPlay/AudioStartWebViewTap
	// call originates from a remote-play-song command (POST
	// /v1/remote/command {"action":"play-song"}) rather than a local click,
	// so the desktop should stay silent for that session while its LAN relay
	// keeps working unchanged. Set via MarkNextPlaybackRemoteInitiated
	// (called by the renderer's handleRemotePlaySongEvent before playSong),
	// consumed exactly once by consumeRemoteInitiatedNext. See
	// progress/remote-play-song.md.
	remoteInitiatedNext atomic.Bool
	// sidecarMu guards sidecarTargetDeviceID, the paired iOS device (if any)
	// currently receiving the fullscreen sidecar now-playing directive via
	// GET /v1/remote/state (see app_sidecar.go).
	sidecarMu             sync.Mutex
	sidecarTargetDeviceID string
}

// NewApp creates a new App struct
func NewApp() *App {
	playlist.SetSettingsProvider(store.Instance)
	lyricssync.SetSettingsProvider(store.Instance)

	return &App{
		dialogs:      headlessDialogProvider{},
		ripper:       cdrip.NewRipper("", config.FFmpegPath, config.GetUserDataPath()),
		mtpManager:   mtp.NewManager(),
		normalizer:   normalize.NewNormalizer(config.FFmpegPath, config.FFprobePath),
		lyricsSyncer: lyricssync.NewSyncer(),
	}
}

// emit forwards an event to the frontend via the injected emitter. In GUI
// mode this reaches wailsRuntime.EventsEmit (wired by wireWailsRuntime);
// headless it is a safe no-op. data may be nil for events that carry no
// payload.
func (a *App) emit(name string, data interface{}) {
	if a == nil || a.ctx == nil {
		return
	}
	emitter := a.playCountsEmitter
	if emitter == nil {
		emitter = eventsEmitFunc
	}
	emitter(a.ctx, name, data)
}

// Startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) Startup(ctx context.Context) {
	a.ctx = ctx
	a.wireWailsRuntime()

	a.bindLyricsSyncProgressEmitter()

	// Before binding port 8765, check whether a resident `--serve` LaunchAgent
	// is already holding it and hand off if so (Phase 0-3; see
	// app_handoff.go). If another GUI instance holds it instead, this
	// deliberately does not take over — StartLANServer's bind failure is
	// logged but non-fatal.
	a.bootedOutResidentAgent = performGUIHandoff(handoffProbeBaseURL)

	// Start the LAN HTTP server for Apple Watch / iPhone / Mobile companion
	StartLANServer(ctx, a)
	fmt.Printf("[LAN] Server address: %s\n", GetLANServerAddress())

	a.initOSMediaControls()
	a.initTray()

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
			a.emit("audio-playback-finished", nil)
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
		a.emit("lyrics-sync-progress", map[string]interface{}{
			"stage":   stage,
			"percent": percent,
		})
	})
}

// pushDiscordPresence updates Discord Rich Presence state.
func (a *App) pushDiscordPresence(_ bool) {}
