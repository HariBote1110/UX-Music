package server

import (
	"context"
	"fmt"
	"os"
	"strconv"
)

// Shutdown is invoked by Wails when the app is closing. It tears down the
// tray and restores a resident LaunchAgent temporarily handed off to the GUI.
func (a *App) Shutdown(ctx context.Context) {
	_ = ctx
	destroyTray()

	// If Startup booted out a resident `--serve` LaunchAgent to take over
	// port 8765, restore it now so KeepAlive resumes managing it. A crash
	// exit skips this (see progress/launchd-handoff.md) — the agent stays
	// booted out until the next GUI launch or login.
	if a.bootedOutResidentAgent {
		uid := strconv.Itoa(os.Getuid())
		plistPath, err := launchAgentPlistPath()
		if err != nil {
			fmt.Printf("[Handoff] could not resolve LaunchAgent plist path: %v\n", err)
			return
		}
		if err := currentLaunchAgentRunner.Bootstrap(uid, plistPath); err != nil {
			fmt.Printf("[Handoff] failed to restore resident agent: %v\n", err)
		}
	}
}
