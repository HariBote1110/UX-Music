package server

import (
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
	case "--serve":
		return true, RunHeadlessServe()
	case "--sync-serve":
		// Deprecated alias for --serve, kept so existing verification scripts
		// and launchd plists keep working. See markdown/appletv-servermode-plan.md
		// Phase 0-2.
		fmt.Println("[Serve] --sync-serve is deprecated; use --serve instead.")
		return true, RunHeadlessServe()
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
