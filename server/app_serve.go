package server

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"ux-music-sidecar/internal/store"
)

// RunHeadlessServe starts the full headless host used by `--serve` (and its
// deprecated alias `--sync-serve`): the LAN HTTP server (all /v1 routes,
// which also starts mDNS advertisement — see StartLANServer), the sync auto
// loop, and an initial library scan. It deliberately does NOT start local
// playback (audio.Player), MTP monitoring, CD ripping, OS media controls, the
// device watcher, or anything that needs a dialog — those require a GUI
// session (see markdown/appletv-servermode-plan.md Phase 0-2).
//
// It blocks until SIGINT/SIGTERM is received or a loopback caller hits
// POST /v1/local/shutdown, then shuts the HTTP server and mDNS advertisement
// down gracefully before returning.
func RunHeadlessServe() error {
	SetServerMode(ModeHeadless)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app := NewApp()
	app.ctx = ctx

	StartLANServer(ctx, app)
	fmt.Printf("[Serve] LAN server address: %s\n", GetLANServerAddress())

	app.startSyncAutoLoop()

	headlessInitialScan(app)

	var stopOnce sync.Once
	stop := make(chan struct{})
	restoreTrigger := setHeadlessShutdownTrigger(func() {
		stopOnce.Do(func() { close(stop) })
	})
	defer restoreTrigger()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)

	select {
	case s := <-sig:
		fmt.Printf("[Serve] received signal %v, shutting down\n", s)
	case <-stop:
		fmt.Println("[Serve] shutdown requested via /v1/local/shutdown")
	}

	cancel()
	// Give the LAN server/mDNS goroutines started by StartLANServer a brief
	// moment to observe ctx.Done() and close cleanly before the process exits.
	time.Sleep(200 * time.Millisecond)
	return nil
}

// headlessInitialScan performs the headless equivalent of the renderer-driven
// "scan library" action. There is no Go-side periodic scan or filesystem
// watcher in this codebase today (scanning is triggered from the frontend via
// the ScanLibrary Wails binding) — see markdown/appletv-servermode-plan.md
// Phase 0-2 for the investigation. The minimal faithful headless equivalent
// is therefore a single scan of the already-configured library folder at
// startup: if `settings.libraryPath` is set, re-scan it (this re-indexes any
// files added while no GUI session ran; ScanLibrary's import step is a no-op
// when source and destination paths already match). If no library path has
// been configured yet, headless mode cannot prompt for one (no dialogs), so
// scanning is skipped with a log message instead of erroring.
func headlessInitialScan(app *App) {
	settings, _ := store.Instance.LoadMap("settings")
	libraryPath, _ := settings["libraryPath"].(string)
	libraryPath = strings.TrimSpace(libraryPath)
	if libraryPath == "" {
		fmt.Println("[Serve] no libraryPath configured yet; skipping initial scan (run the GUI once to set one)")
		return
	}
	fmt.Printf("[Serve] running initial library scan of %s\n", libraryPath)
	result := app.ScanLibrary([]string{libraryPath})
	fmt.Printf("[Serve] initial scan found %d new/updated song(s)\n", result.Count)
}
