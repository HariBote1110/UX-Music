package server

// trayPlayPauseLabel maps the current playback state to the label shown on
// the tray menu's play/pause item. Pure function, unit tested in
// app_tray_test.go.
func trayPlayPauseLabel(playing bool) string {
	if playing {
		return "一時停止"
	}
	return "再生"
}

// initTray creates the macOS menu-bar NSStatusItem and wires its menu
// commands to the same paths already used by the OS media-key handler
// (a.emit("os-media-command", ...), consumed by the renderer in
// renderer.ts) and by the window/quit runtime calls. GUI-mode only: headless
// (--serve) never calls this. See progress/menubar-tray-mode.md.
func (a *App) initTray() {
	createTray(func(command int) {
		switch command {
		case trayCommandShowWindow:
			a.trayShowWindow()
		case trayCommandPlayPause:
			a.emit("os-media-command", "toggle")
		case trayCommandNext:
			a.emit("os-media-command", "next")
		case trayCommandPrevious:
			a.emit("os-media-command", "previous")
		case trayCommandQuit:
			a.trayQuit()
		}
	})
	// Set the initial label; later transitions are kept in sync by
	// updateOSPlaybackState (app_media.go), the single choke point already
	// used for every play/pause/resume/finish state change.
	setTrayPlayPauseLabel(trayPlayPauseLabel(a.AudioIsPlaying()))
}
