package server

import (
	"errors"
	"fmt"
	"os"
	"strings"
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

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return nil, errors.New("library store format is invalid")
	}
	if len(library) == 0 {
		return []string{}, nil
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

// SaveAlbumSongOrder persists a custom play order for an album.
// orderedSongIds is the desired sequence of song IDs (index 0 = first).
// Each matching song gets a customOrder field (1-based) written to library.json.
func (a *App) SaveAlbumSongOrder(albumKey string, orderedSongIds []string) error {
	if len(orderedSongIds) == 0 {
		return nil
	}

	// Build position lookup: songId → 1-based order
	orderMap := make(map[string]int, len(orderedSongIds))
	for i, id := range orderedSongIds {
		orderMap[id] = i + 1
	}

	arr, err := store.Instance.LoadSlice("library")
	if err != nil {
		return errors.New("library store format is invalid")
	}

	normKey := strings.ToLower(strings.TrimSpace(albumKey))
	for _, item := range arr {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		album, _ := m["album"].(string)
		if strings.ToLower(strings.TrimSpace(album)) != normKey {
			continue
		}
		id, _ := m["id"].(string)
		if pos, found := orderMap[id]; found {
			m["customOrder"] = pos
		}
	}

	if err := store.Instance.Save("library", arr); err != nil {
		return fmt.Errorf("failed to save library: %w", err)
	}

	wailsRuntime.EventsEmit(a.ctx, "album-order-saved", map[string]interface{}{
		"albumKey":       albumKey,
		"orderedSongIds": orderedSongIds,
	})
	return nil
}
