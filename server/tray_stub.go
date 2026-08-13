//go:build !darwin

package server

// createTray, setTrayPlayPauseLabel and destroyTray are no-ops on
// non-Darwin platforms: the menu-bar NSStatusItem is a macOS-only concept
// (see progress/menubar-tray-mode.md).
func createTray(callback func(int)) {}

func setTrayPlayPauseLabel(label string) {}

func destroyTray() {}
