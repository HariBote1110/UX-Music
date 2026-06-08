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
