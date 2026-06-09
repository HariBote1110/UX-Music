// Command synctest is a head-less entry point for UX Music Sync verification.
//
// It exposes the same sync CLI as the GUI binary (via server.RunSyncCLI) but
// does NOT embed the renderer assets, so it can be built without the Wails
// front-end bundle on a verification node.
package main

import (
	"os"
	"path/filepath"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/server"
)

func main() {
	configDir, _ := os.UserConfigDir()
	config.SetUserDataPath(filepath.Join(configDir, "ux-music"))

	if handled, err := server.RunSyncCLI(os.Args[1:]); handled {
		if err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}

	println("usage: synctest --sync-serve | --sync-auto-once | --sync-pull <url> | --sync-pair <url> | --sync-reset-test-data")
}
