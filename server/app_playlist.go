package server

import (
	"fmt"
	"sort"
	"strings"
	"time"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"

	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// LoadLibrary loads the library and emits an event
func (a *App) LoadLibrary() {
	fmt.Println("[Wails] LoadLibrary current")
	songs, _ := store.Instance.Load("library")

	if songs == nil {
		songs = []interface{}{}
	}

	// Ensure all songs have stable ids for UI selection/highlight logic.
	if arr, ok := songs.([]interface{}); ok {
		migrated := false
		for _, item := range arr {
			songMap, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			id, _ := songMap["id"].(string)
			path, _ := songMap["path"].(string)
			if strings.TrimSpace(id) == "" && strings.TrimSpace(path) != "" {
				songMap["id"] = uuid.NewString()
				migrated = true
			}
		}
		if migrated {
			_ = store.Instance.Save("library", arr)
		}
		songs = arr
	}

	data := map[string]interface{}{
		"songs":  songs,
		"albums": make(map[string]interface{}),
	}
	wailsRuntime.EventsEmit(a.ctx, "load-library", data)
}

// RequestInitialLibrary is a helper for initial load
func (a *App) RequestInitialLibrary() {
	a.LoadLibrary()
}

// LoadPlayCounts loads play counts and emits an event
func (a *App) LoadPlayCounts() {
	fmt.Println("[Wails] LoadPlayCounts called")
	counts, _ := store.Instance.Load("playcounts")
	if counts == nil {
		counts = make(map[string]interface{})
	}
	wailsRuntime.EventsEmit(a.ctx, "play-counts-updated", counts)
}

// IncrementPlayCount increments the play count for a song
func (a *App) IncrementPlayCount(song map[string]interface{}) {
	fmt.Printf("[Wails] IncrementPlayCount called for: %v\n", song["title"])
	path, ok := song["path"].(string)
	if !ok {
		return
	}

	counts, _ := store.Instance.Load("playcounts")
	var countsMap map[string]interface{}
	if counts == nil {
		countsMap = make(map[string]interface{})
	} else {
		countsMap = counts.(map[string]interface{})
	}

	isoNow := time.Now().Format(time.RFC3339)

	var existingData map[string]interface{}
	if data, exists := countsMap[path]; exists {
		existingData = data.(map[string]interface{})
	} else {
		existingData = map[string]interface{}{
			"count":         0.0,
			"totalDuration": 0.0,
			"history":       []interface{}{},
		}
	}

	existingData["count"] = existingData["count"].(float64) + 1
	if duration, ok := song["duration"].(float64); ok {
		existingData["totalDuration"] = existingData["totalDuration"].(float64) + duration
	}

	history := existingData["history"].([]interface{})
	history = append(history, isoNow)
	if len(history) > 100 {
		history = history[1:]
	}
	existingData["history"] = history

	countsMap[path] = existingData
	store.Instance.Save("playcounts", countsMap)

	wailsRuntime.EventsEmit(a.ctx, "play-counts-updated", countsMap)
}

// SongFinished handles the end of a song, updating analysis score
func (a *App) SongFinished(song map[string]interface{}) {
	fmt.Printf("[Wails] SongFinished called for: %v\n", song["title"])
	id, ok := song["id"].(string)
	if !ok {
		return
	}

	data, _ := store.Instance.Load("analysed-queue")
	if data == nil {
		return
	}

	analysedData := data.(map[string]interface{})
	if songData, exists := analysedData[id]; exists {
		sMap := songData.(map[string]interface{})
		score := sMap["score"].(float64)
		if score > 0 {
			sMap["score"] = score - 1
			analysedData[id] = sMap
			store.Instance.Save("analysed-queue", analysedData)
		}
	}
}

func (a *App) SongSkipped(data map[string]interface{}) {
	song := data["song"].(map[string]interface{})
	currentTime := data["currentTime"].(float64)

	id, ok := song["id"].(string)
	duration, okDur := song["duration"].(float64)
	if !ok || !okDur || duration == 0 {
		return
	}

	playbackPercentage := (currentTime / duration) * 100
	var scoreIncrement float64 = 0

	if currentTime <= 5 {
		scoreIncrement = 5
	} else if playbackPercentage <= 10 {
		scoreIncrement = 3
	} else if playbackPercentage <= 50 {
		scoreIncrement = 1
	}

	if scoreIncrement > 0 {
		dislikeData, _ := store.Instance.Load("analysed-queue")
		var dislikeMap map[string]interface{}
		if dislikeData == nil {
			dislikeMap = make(map[string]interface{})
		} else {
			dislikeMap = dislikeData.(map[string]interface{})
		}

		var currentData map[string]interface{}
		if d, exists := dislikeMap[id]; exists {
			currentData = d.(map[string]interface{})
		} else {
			currentData = map[string]interface{}{"score": 0.0}
		}

		currentData["score"] = currentData["score"].(float64) + scoreIncrement
		currentData["lastSkipped"] = time.Now().Format(time.RFC3339)

		dislikeMap[id] = currentData
		store.Instance.Save("analysed-queue", dislikeMap)
	}
}

// RequestPlaylistsWithArtwork loads playlists and emits an event
func (a *App) RequestPlaylistsWithArtwork() {
	playlistNames, err := playlist.GetAllPlaylists()
	if err != nil {
		wailsRuntime.EventsEmit(a.ctx, "playlists-updated", []interface{}{})
		return
	}

	library, _ := store.Instance.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	pathToArtwork := make(map[string]string)
	for _, s := range librarySongs {
		song := s.(map[string]interface{})
		if path, ok := song["path"].(string); ok {
			if artwork, ok := song["artwork"].(string); ok && artwork != "" {
				pathToArtwork[path] = artwork
			}
		}
	}

	var playlists []interface{}
	for _, name := range playlistNames {
		songPaths, _ := playlist.GetPlaylistSongs(name)

		var artworks []string
		seenArtworks := make(map[string]bool)
		for _, path := range songPaths {
			if artwork, exists := pathToArtwork[path]; exists && !seenArtworks[artwork] {
				artworks = append(artworks, artwork)
				seenArtworks[artwork] = true
				if len(artworks) >= 4 {
					break
				}
			}
		}

		playlists = append(playlists, map[string]interface{}{
			"name":     name,
			"artworks": artworks,
		})
	}

	wailsRuntime.EventsEmit(a.ctx, "playlists-updated", playlists)
}

// GetPlaylistDetails returns the songs in a playlist
func (a *App) GetPlaylistDetails(name string) (interface{}, error) {
	paths, err := playlist.GetPlaylistSongs(name)
	if err != nil {
		return nil, err
	}

	library, _ := store.Instance.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	playlistSongs := make([]interface{}, 0)
	for _, p := range paths {
		for _, s := range librarySongs {
			song := s.(map[string]interface{})
			if song["path"] == p {
				playlistSongs = append(playlistSongs, s)
				break
			}
		}
	}

	return map[string]interface{}{
		"name":  name,
		"songs": playlistSongs,
	}, nil
}

// GetSituationPlaylists returns generated playlists for "For You"
func (a *App) GetSituationPlaylists() (interface{}, error) {
	result := make(map[string]interface{})
	library, _ := store.Instance.Load("library")
	if library == nil {
		return result, nil
	}

	songs := library.([]interface{})
	if len(songs) == 0 {
		return result, nil
	}

	recentSongs := make([]interface{}, 0)
	maxRecent := 20
	if len(songs) < maxRecent {
		maxRecent = len(songs)
	}
	for i := len(songs) - 1; i >= len(songs)-maxRecent && i >= 0; i-- {
		recentSongs = append(recentSongs, songs[i])
	}
	if len(recentSongs) > 0 {
		result["recently_added"] = map[string]interface{}{
			"name":  "最近追加した曲",
			"songs": recentSongs,
		}
	}

	playCounts, _ := store.Instance.Load("playcounts")
	if playCounts != nil {
		countsMap := playCounts.(map[string]interface{})
		if len(countsMap) > 0 {
			type songWithCount struct {
				song  interface{}
				count int
			}
			var songsWithCounts []songWithCount

			for _, s := range songs {
				song := s.(map[string]interface{})
				path, ok := song["path"].(string)
				if !ok {
					continue
				}
				if countData, exists := countsMap[path]; exists {
					countMap := countData.(map[string]interface{})
					if count, ok := countMap["count"].(float64); ok && count > 0 {
						songsWithCounts = append(songsWithCounts, songWithCount{song: s, count: int(count)})
					}
				}
			}

			sort.Slice(songsWithCounts, func(i, j int) bool {
				return songsWithCounts[i].count > songsWithCounts[j].count
			})

			mostPlayedSongs := make([]interface{}, 0)
			maxPlayed := 20
			if len(songsWithCounts) < maxPlayed {
				maxPlayed = len(songsWithCounts)
			}
			for i := 0; i < maxPlayed; i++ {
				mostPlayedSongs = append(mostPlayedSongs, songsWithCounts[i].song)
			}

			if len(mostPlayedSongs) > 0 {
				result["most_played"] = map[string]interface{}{
					"name":  "よく聴く曲",
					"songs": mostPlayedSongs,
				}
			}
		}
	}

	if len(songs) >= 5 {
		randomSongs := make([]interface{}, 0)
		maxRandom := 20
		if len(songs) < maxRandom {
			maxRandom = len(songs)
		}
		step := len(songs) / maxRandom
		if step < 1 {
			step = 1
		}
		for i := 0; i < len(songs) && len(randomSongs) < maxRandom; i += step {
			randomSongs = append(randomSongs, songs[i])
		}
		if len(randomSongs) > 0 {
			result["random_pick"] = map[string]interface{}{
				"name":  "ランダムピック",
				"songs": randomSongs,
			}
		}
	}

	return result, nil
}

// CreatePlaylist moves the playlist creation logic to Go
func (a *App) CreatePlaylist(name string) error {
	err := playlist.CreatePlaylist(name)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// GetAllPlaylists returns all playlist names
func (a *App) GetAllPlaylists() ([]string, error) {
	return playlist.GetAllPlaylists()
}

// DeletePlaylist deletes a playlist
func (a *App) DeletePlaylist(name string) error {
	err := playlist.DeletePlaylist(name)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// RenamePlaylist renames a playlist
func (a *App) RenamePlaylist(data map[string]interface{}) error {
	oldName := data["oldName"].(string)
	newName := data["newName"].(string)
	err := playlist.RenamePlaylist(oldName, newName)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// AddSongsToPlaylist adds songs to a playlist
func (a *App) AddSongsToPlaylist(data map[string]interface{}) (int, error) {
	name := data["playlistName"].(string)
	songsData := data["songs"].([]interface{})
	var songs []playlist.SongToAdd
	for _, s := range songsData {
		sm := s.(map[string]interface{})
		songs = append(songs, playlist.SongToAdd{
			Path:     sm["path"].(string),
			Duration: sm["duration"].(float64),
			Artist:   sm["artist"].(string),
			Title:    sm["title"].(string),
		})
	}
	count, err := playlist.AddSongsToPlaylist(name, songs)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return count, err
}

// AddAlbumToPlaylist adds all songs in an album to a playlist
func (a *App) AddAlbumToPlaylist(data map[string]interface{}) (map[string]interface{}, error) {
	playlistName := data["playlistName"].(string)
	songPaths := data["songPaths"].([]interface{})

	library, _ := store.Instance.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	var songsToAdd []playlist.SongToAdd
	for _, p := range songPaths {
		pathStr := p.(string)
		for _, s := range librarySongs {
			song := s.(map[string]interface{})
			if song["path"] == pathStr {
				songsToAdd = append(songsToAdd, playlist.SongToAdd{
					Path:     song["path"].(string),
					Duration: song["duration"].(float64),
					Artist:   song["artist"].(string),
					Title:    song["title"].(string),
				})
				break
			}
		}
	}

	count, err := playlist.AddSongsToPlaylist(playlistName, songsToAdd)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return map[string]interface{}{"success": err == nil, "addedCount": count}, err
}

// UpdatePlaylistSongOrder updates the order of songs in a playlist
func (a *App) UpdatePlaylistSongOrder(data map[string]interface{}) error {
	name := data["playlistName"].(string)
	pathsData := data["paths"].([]interface{})
	var paths []string
	for _, p := range pathsData {
		paths = append(paths, p.(string))
	}
	err := playlist.UpdatePlaylistOrder(name, paths)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}
