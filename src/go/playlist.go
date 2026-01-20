package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	PlaylistsDirName      = "Playlists"
	PlaylistOrderFileName = "playlist-order"
	FavoritesPlaylistName = "お気に入り"
)

func GetPlaylistsDir() string {
	dir := filepath.Join(config.GetUserDataPath(), PlaylistsDirName)
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		os.MkdirAll(dir, 0755)
	}
	return dir
}

// PlaylistEntry represents a single song entry in an M3U8 file
type PlaylistEntry struct {
	Path     string
	Duration int
	Title    string
}

func parseM3U8(content string) []PlaylistEntry {
	lines := strings.Split(content, "\n")
	var entries []PlaylistEntry

	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if strings.HasPrefix(line, "#EXTINF:") {
			// Parse EXTINF: duration,title
			parts := strings.SplitN(line[8:], ",", 2)
			duration := 0
			title := ""
			if len(parts) >= 2 {
				fmt.Sscanf(parts[0], "%d", &duration)
				title = parts[1]
			}

			// Next line should be the path
			if i+1 < len(lines) {
				pathLine := strings.TrimSpace(lines[i+1])
				if pathLine != "" && !strings.HasPrefix(pathLine, "#") {
					entries = append(entries, PlaylistEntry{
						Path:     pathLine,
						Duration: duration,
						Title:    title,
					})
					i++ // Skip path line
				}
			}
		}
	}
	return entries
}

func writeM3U8(path string, entries []PlaylistEntry) error {
	var sb strings.Builder
	sb.WriteString("#EXTM3U\n")

	for _, entry := range entries {
		sb.WriteString(fmt.Sprintf("#EXTINF:%d,%s\n", entry.Duration, entry.Title))
		sb.WriteString(entry.Path + "\n")
	}

	return os.WriteFile(path, []byte(sb.String()), 0644)
}

func GetAllPlaylists() ([]string, error) {
	dir := GetPlaylistsDir()
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	var names []string
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(f.Name(), ".m3u8") {
			names = append(names, strings.TrimSuffix(f.Name(), ".m3u8"))
		}
	}

	// Load order
	orderData, _ := stores.Load(PlaylistOrderFileName)
	var savedOrder []string
	if orderMap, ok := orderData.(map[string]interface{}); ok {
		if orderList, ok := orderMap["order"].([]interface{}); ok {
			for _, item := range orderList {
				if s, ok := item.(string); ok {
					savedOrder = append(savedOrder, s)
				}
			}
		}
	}

	// Sort based on saved order + remaining alphabetical
	orderMap := make(map[string]int)
	for i, name := range savedOrder {
		orderMap[name] = i
	}

	sort.Slice(names, func(i, j int) bool {
		idxI, okI := orderMap[names[i]]
		idxJ, okJ := orderMap[names[j]]

		if okI && okJ {
			return idxI < idxJ
		}
		if okI {
			return true
		}
		if okJ {
			return false
		}
		return names[i] < names[j]
	})

	return names, nil
}

func CreatePlaylist(name string) error {
	if name == "" {
		return fmt.Errorf("empty name")
	}
	path := filepath.Join(GetPlaylistsDir(), name+".m3u8")
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("playlist already exists")
	}

	return os.WriteFile(path, []byte("#EXTM3U\n"), 0644)
}

func DeletePlaylist(name string) error {
	path := filepath.Join(GetPlaylistsDir(), name+".m3u8")
	return os.Remove(path)
}

func GetPlaylistSongs(name string) ([]string, error) {
	path := filepath.Join(GetPlaylistsDir(), name+".m3u8")
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	entries := parseM3U8(string(content))
	paths := make([]string, len(entries))
	for i, e := range entries {
		paths[i] = e.Path
	}
	return paths, nil
}

// Simple song struct for adding
type SongToAdd struct {
	Path     string  `json:"path"`
	Duration float64 `json:"duration"`
	Artist   string  `json:"artist"`
	Title    string  `json:"title"`
}

func AddSongsToPlaylist(name string, songs []SongToAdd) (int, error) {
	path := filepath.Join(GetPlaylistsDir(), name+".m3u8")
	content, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}

	currentEntries := parseM3U8(string(content))
	existingPaths := make(map[string]bool)
	for _, e := range currentEntries {
		existingPaths[e.Path] = true
	}

	addedCount := 0
	for _, s := range songs {
		if !existingPaths[s.Path] {
			currentEntries = append(currentEntries, PlaylistEntry{
				Path:     s.Path,
				Duration: int(s.Duration),
				Title:    fmt.Sprintf("%s - %s", s.Artist, s.Title),
			})
			addedCount++
		}
	}

	if addedCount > 0 {
		err = writeM3U8(path, currentEntries)
	}

	return addedCount, err
}

func RenamePlaylist(oldName, newName string) error {
	oldPath := filepath.Join(GetPlaylistsDir(), oldName+".m3u8")
	newPath := filepath.Join(GetPlaylistsDir(), newName+".m3u8")

	if _, err := os.Stat(newPath); err == nil {
		return fmt.Errorf("destination playlist already exists")
	}

	return os.Rename(oldPath, newPath)
}
