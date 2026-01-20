package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx context.Context
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
}

// Ping returns a pong message
func (a *App) Ping() string {
	return "pong from Wails!"
}

// ScanLibrary calls the existing ScanLibrary logic
func (a *App) ScanLibrary(paths []string) ScanResult {
	fmt.Printf("[Wails] Scanning library: %v\n", paths)
	return ScanLibrary(paths)
}

// GetYouTubeInfo calls the existing GetYouTubeVideoInfo logic
func (a *App) GetYouTubeInfo(url string) (interface{}, error) {
	return GetYouTubeVideoInfo(url)
}

// GetSettings loads settings from settings.json
func (a *App) GetSettings() (interface{}, error) {
	fmt.Println("[Wails] GetSettings called")
	data, err := stores.Load("settings")
	if err != nil {
		return nil, err
	}
	if data == nil {
		return make(map[string]interface{}), nil
	}
	return data, nil
}

// SaveSettings saves the application settings
func (a *App) SaveSettings(settings interface{}) error {
	fmt.Printf("[Wails] SaveSettings called: %v\n", settings)

	// Merge with existing settings
	current, _ := stores.Load("settings")
	if current == nil {
		current = make(map[string]interface{})
	}

	currentMap := current.(map[string]interface{})
	newMap := settings.(map[string]interface{})

	for k, v := range newMap {
		currentMap[k] = v
	}

	return stores.Save("settings", currentMap)
}

// GetArtworksDir returns the path to the artworks directory
func (a *App) GetArtworksDir() string {
	return filepath.Join(config.GetUserDataPath(), "Artworks")
}

// LoadLibrary loads the library and emits an event
func (a *App) LoadLibrary() {
	fmt.Println("[Wails] LoadLibrary current")
	songs, _ := stores.Load("library")
	albums, _ := stores.Load("albums")

	if songs == nil {
		songs = []interface{}{}
	}
	if albums == nil {
		albums = make(map[string]interface{})
	}

	data := map[string]interface{}{
		"songs":  songs,
		"albums": albums,
	}
	runtime.EventsEmit(a.ctx, "load-library", data)
}

// RequestInitialLibrary is a helper for initial load
func (a *App) RequestInitialLibrary() {
	a.LoadLibrary()
}

// LoadPlayCounts loads play counts and emits an event
func (a *App) LoadPlayCounts() {
	counts, _ := stores.Load("play-counts")
	if counts == nil {
		counts = make(map[string]interface{})
	}
	runtime.EventsEmit(a.ctx, "play-counts-updated", counts)
}

// RequestPlaylistsWithArtwork loads playlists and emits an event
func (a *App) RequestPlaylistsWithArtwork() {
	fmt.Println("[Wails] RequestPlaylistsWithArtwork called")
	playlists, _ := stores.Load("playlists")
	if playlists == nil {
		playlists = []interface{}{}
	}
	runtime.EventsEmit(a.ctx, "playlists-updated", playlists)
}

// GetPlaylistDetails returns the songs in a playlist
func (a *App) GetPlaylistDetails(name string) (interface{}, error) {
	fmt.Printf("[Wails] GetPlaylistDetails called: %s\n", name)
	paths, err := GetPlaylistSongs(name)
	if err != nil {
		return nil, err
	}

	library, _ := stores.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	var playlistSongs []interface{}
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
	fmt.Println("[Wails] GetSituationPlaylists called")
	// TODO: Replace with sidecar logic in future phase
	return make(map[string]interface{}), nil
}

// CreatePlaylist moves the playlist creation logic to Go
func (a *App) CreatePlaylist(name string) error {
	err := CreatePlaylist(name)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// GetAllPlaylists returns all playlist names
func (a *App) GetAllPlaylists() ([]string, error) {
	return GetAllPlaylists()
}

// DeletePlaylist deletes a playlist
func (a *App) DeletePlaylist(name string) error {
	err := DeletePlaylist(name)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// RenamePlaylist renames a playlist
func (a *App) RenamePlaylist(data map[string]interface{}) error {
	oldName := data["oldName"].(string)
	newName := data["newName"].(string)
	err := RenamePlaylist(oldName, newName)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// GetLoudnessValue returns the saved loudness for a song
func (a *App) GetLoudnessValue(path string) (interface{}, error) {
	data, _ := stores.Load("loudness")
	if data == nil {
		return nil, nil
	}
	loudnessMap := data.(map[string]interface{})
	return loudnessMap[path], nil
}

// GetLyrics finds lyrics for a song
func (a *App) GetLyrics(fileName string) (interface{}, error) {
	return FindLyrics(fileName)
}

// SaveLrcFile saves a lyrics file
func (a *App) SaveLrcFile(fileName string, content string) error {
	return SaveLrcFile(fileName, content)
}

// HandleLyricsDrop handles dragging and dropping lyrics files
func (a *App) HandleLyricsDrop(paths []string) error {
	count, err := CopyLyricsFiles(paths)
	if err == nil && count > 0 {
		runtime.EventsEmit(a.ctx, "lyrics-added-notification", count)
	}
	return err
}

// AddSongsToPlaylist adds songs to a playlist
func (a *App) AddSongsToPlaylist(data map[string]interface{}) (int, error) {
	name := data["playlistName"].(string)
	songsData := data["songs"].([]interface{})
	var songs []SongToAdd
	for _, s := range songsData {
		sm := s.(map[string]interface{})
		songs = append(songs, SongToAdd{
			Path:     sm["path"].(string),
			Duration: sm["duration"].(float64),
			Artist:   sm["artist"].(string),
			Title:    sm["title"].(string),
		})
	}
	count, err := AddSongsToPlaylist(name, songs)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return count, err
}

// AddAlbumToPlaylist adds all songs in an album to a playlist
func (a *App) AddAlbumToPlaylist(data map[string]interface{}) (map[string]interface{}, error) {
	playlistName := data["playlistName"].(string)
	songPaths := data["songPaths"].([]interface{})

	library, _ := stores.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	var songsToAdd []SongToAdd
	for _, p := range songPaths {
		pathStr := p.(string)
		for _, s := range librarySongs {
			song := s.(map[string]interface{})
			if song["path"] == pathStr {
				songsToAdd = append(songsToAdd, SongToAdd{
					Path:     song["path"].(string),
					Duration: song["duration"].(float64),
					Artist:   song["artist"].(string),
					Title:    song["title"].(string),
				})
				break
			}
		}
	}

	count, err := AddSongsToPlaylist(playlistName, songsToAdd)
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
	err := UpdatePlaylistOrder(name, paths)
	if err == nil {
		a.RequestPlaylistsWithArtwork()
	}
	return err
}

// GetArtworkAsDataURL reads an artwork file and returns it as a base64 data URL
func (a *App) GetArtworkAsDataURL(filename string) (string, error) {
	if filename == "" {
		return "", nil
	}

	userDataPath := config.GetUserDataPath()
	artworksDir := filepath.Join(userDataPath, "Artworks")
	fullPath := filepath.Join(artworksDir, filename)

	data, err := os.ReadFile(fullPath)
	if err != nil {
		return "", nil // Ignore errors, return empty
	}

	mimeType := "image/jpeg"
	if strings.HasSuffix(strings.ToLower(filename), ".png") {
		mimeType = "image/png"
	} else if strings.HasSuffix(strings.ToLower(filename), ".webp") {
		mimeType = "image/webp"
	}

	base64Data := base64.StdEncoding.EncodeToString(data)
	return fmt.Sprintf("data:%s;base64,%s", mimeType, base64Data), nil
}
