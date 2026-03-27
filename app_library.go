package main

import (
	"errors"
	"fmt"
	"os"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// DeleteSongs deletes songs from library and (optionally) from disk.
func (a *App) DeleteSongs(paths []string, deleteFiles bool) ([]string, error) {
	fmt.Printf("[Wails] DeleteSongs called: count=%d deleteFiles=%v\n", len(paths), deleteFiles)
	if len(paths) == 0 {
		return []string{}, nil
	}

	pathSet := make(map[string]struct{}, len(paths))
	for _, p := range paths {
		if p != "" {
			pathSet[p] = struct{}{}
		}
	}
	if len(pathSet) == 0 {
		return []string{}, nil
	}

	raw, _ := store.Instance.Load("library")
	if raw == nil {
		return []string{}, nil
	}

	library, ok := raw.([]interface{})
	if !ok {
		return nil, errors.New("library store format is invalid")
	}

	updated := make([]interface{}, 0, len(library))
	deletedPaths := make([]string, 0, len(pathSet))

	for _, item := range library {
		songMap, ok := item.(map[string]interface{})
		if !ok {
			updated = append(updated, item)
			continue
		}
		p, _ := songMap["path"].(string)
		if _, remove := pathSet[p]; remove {
			deletedPaths = append(deletedPaths, p)
			continue
		}
		updated = append(updated, item)
	}

	if len(deletedPaths) == 0 {
		fmt.Println("[Wails] DeleteSongs: no matching songs in library")
		return []string{}, nil
	}

	if err := store.Instance.Save("library", updated); err != nil {
		fmt.Printf("[Wails] DeleteSongs: save failed: %v\n", err)
		return nil, err
	}

	if deleteFiles {
		for _, p := range deletedPaths {
			if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
				// Keep going: library state should remain consistent even if some file deletions fail.
			}
		}
	}

	if playlistNames, err := playlist.GetAllPlaylists(); err == nil {
		for _, name := range playlistNames {
			_ = playlist.RemoveSongsFromPlaylist(name, deletedPaths)
		}
	}

	wailsRuntime.EventsEmit(a.ctx, "songs-deleted", deletedPaths)
	a.RequestPlaylistsWithArtwork()
	fmt.Printf("[Wails] DeleteSongs completed: deleted=%d\n", len(deletedPaths))
	return deletedPaths, nil
}
