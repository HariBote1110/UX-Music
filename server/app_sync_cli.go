package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
)

func RunSyncCLI(args []string) (bool, error) {
	if len(args) == 0 {
		return false, nil
	}
	switch args[0] {
	case "--sync-reset-test-data":
		result, err := ResetSyncTestData()
		if err != nil {
			return true, err
		}
		return true, writeSyncCLIJSON(result)
	case "--sync-pair":
		if len(args) < 2 {
			return true, fmt.Errorf("--sync-pair requires a peer base URL")
		}
		app := NewApp()
		started, err := app.StartSyncPairing(args[1])
		if err != nil {
			return true, err
		}
		confirmed, err := app.ConfirmSyncPairing(started.BaseURL, started.SessionID, started.Code, started.RemoteDeviceID)
		if err != nil {
			return true, err
		}
		return true, writeSyncCLIJSON(map[string]interface{}{
			"started":   started,
			"confirmed": confirmed,
		})
	case "--sync-auto-once":
		result, err := NewApp().AutoSyncPairedDevices()
		if err != nil {
			return true, err
		}
		return true, writeSyncCLIJSON(result)
	case "--sync-serve":
		// Start the LAN sync HTTP server head-less (no Wails GUI) so a machine
		// can act as a sync receiver for verification without a desktop session.
		app := NewApp()
		StartLANServer(context.Background(), app)
		fmt.Println("[Sync] head-less sync server listening on :" + lanServerPort)
		select {}
	case "--sync-pull":
		if len(args) < 2 {
			return true, fmt.Errorf("--sync-pull requires a peer base URL")
		}
		result, err := NewApp().PullSyncLibraryAssets(args[1], 0)
		if err != nil {
			return true, err
		}
		return true, writeSyncCLIJSON(result)
	case "--sync-pull-one":
		if len(args) < 2 {
			return true, fmt.Errorf("--sync-pull-one requires a peer base URL")
		}
		result, err := NewApp().PullSyncLibraryAssets(args[1], 1)
		if err != nil {
			return true, err
		}
		return true, writeSyncCLIJSON(result)
	default:
		return false, nil
	}
}

func writeSyncCLIJSON(value interface{}) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}
