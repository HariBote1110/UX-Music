package server

import (
	"fmt"
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
	data, err := a.GetUnifiedLibrary()
	if err != nil {
		data = map[string]interface{}{
			"songs":  []interface{}{},
			"albums": make(map[string]interface{}),
		}
	}
	wailsRuntime.EventsEmit(a.ctx, "load-library", data)
}

func (a *App) GetUnifiedLibrary() (map[string]interface{}, error) {
	songs, err := store.Instance.LoadSlice("library")
	if err != nil {
		return nil, err
	}

	migrated := false
	localMatchKeys := map[string]bool{}
	unified := make([]interface{}, 0, len(songs))
	for _, item := range songs {
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
		localSong := cloneSyncMap(songMap)
		localSong["syncAvailability"] = "local"
		if key := syncSongMatchKey(localSong); key != "" {
			localMatchKeys[key] = true
		}
		unified = append(unified, localSong)
	}
	if migrated {
		_ = store.Instance.Save("library", songs)
	}

	remoteSongs := syncUnifiedRemoteSongs(localMatchKeys)
	unified = append(unified, remoteSongs...)

	return map[string]interface{}{
		"songs":  unified,
		"albums": make(map[string]interface{}),
	}, nil
}

// RequestInitialLibrary is a helper for initial load
func (a *App) RequestInitialLibrary() {
	a.LoadLibrary()
}

// LoadPlayCounts loads play counts and emits an event
func (a *App) LoadPlayCounts() {
	fmt.Println("[Wails] LoadPlayCounts called")
	counts, _ := store.Instance.LoadMap("playcounts")
	wailsRuntime.EventsEmit(a.ctx, "play-counts-updated", counts)
}

// IncrementPlayCount increments the play count for a song
func (a *App) IncrementPlayCount(song map[string]interface{}) {
	fmt.Printf("[Wails] IncrementPlayCount called for: %v\n", song["title"])
	path, ok := song["path"].(string)
	if !ok {
		return
	}

	now := time.Now()
	_ = ensureSyncPlayCountBaseMigrated()
	_ = recordLocalSyncPlayEvent(song, now.UTC())
	_ = recalculateAllSyncPlayCounts()
	countsMap, _ := store.Instance.LoadMap("playcounts")
	if _, exists := countsMap[path]; !exists {
		entry := normalisePlayCountEntry(nil)
		countsMap[path] = entry
		_ = store.Instance.Save("playcounts", countsMap)
	}

	if a.ctx != nil {
		wailsRuntime.EventsEmit(a.ctx, "play-counts-updated", countsMap)
	}
}

// SongFinished handles the end of a song, updating analysis score
func (a *App) SongFinished(song map[string]interface{}) {
	fmt.Printf("[Wails] SongFinished called for: %v\n", song["title"])
	id, ok := song["id"].(string)
	if !ok {
		return
	}

	analysedData, _ := store.Instance.LoadMap("analysed-queue")
	if len(analysedData) == 0 {
		return
	}
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
		dislikeMap, _ := store.Instance.LoadMap("analysed-queue")

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

	librarySongs, _ := store.Instance.LoadSlice("library")

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

	librarySongs, _ := store.Instance.LoadSlice("library")

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
	songs, _ := store.Instance.LoadSlice("library")
	if len(songs) == 0 {
		return result, nil
	}

	if recent := pickRecentlyAdded(songs, situationPlaylistMaxItems); len(recent) > 0 {
		result["recently_added"] = map[string]interface{}{
			"name":  "最近追加した曲",
			"songs": recent,
		}
	}

	counts, _ := store.Instance.LoadMap("playcounts")
	if mostPlayed := pickMostPlayed(songs, counts, situationPlaylistMaxItems); len(mostPlayed) > 0 {
		result["most_played"] = map[string]interface{}{
			"name":  "よく聴く曲",
			"songs": mostPlayed,
		}
	}

	if random := pickRandomPick(songs, situationPlaylistMaxItems); len(random) > 0 {
		result["random_pick"] = map[string]interface{}{
			"name":  "ランダムピック",
			"songs": random,
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

	librarySongs, _ := store.Instance.LoadSlice("library")

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
