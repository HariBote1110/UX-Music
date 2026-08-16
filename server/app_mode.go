package server

// Server run mode. Set once at process startup (main.go for GUI mode,
// runHeadlessServe for `--serve`) and read by the identity/mDNS advertise
// info and by the loopback-only shutdown endpoint. Kept as a package-level
// variable rather than threading a parameter through every handler because
// the mode is fixed for the lifetime of the process.
const (
	// ModeGUI is the default mode: the Wails desktop app is running.
	ModeGUI = "gui"
	// ModeHeadless is set by `--serve` (and its deprecated alias
	// `--sync-serve`): no Wails runtime, no local playback/dialogs.
	ModeHeadless = "headless"
)

var currentServerMode = ModeGUI

// SetServerMode records which mode the process is running in. Call once at
// startup before the LAN HTTP server is created.
func SetServerMode(mode string) {
	currentServerMode = mode
}

// CurrentServerMode returns the process-wide server mode set by SetServerMode.
func CurrentServerMode() string {
	return currentServerMode
}
