package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx          context.Context
	cdRipSidecar *NodeSidecar
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Initialize CD-RIP sidecar
	// 開発環境と製品環境でパスを切り替える必要があるが、一旦開発用パス
	scriptPath := filepath.Join("src", "sidecars", "cd-rip", "index.js")
	// もし絶対パスが必要なら調整
	absPath, _ := filepath.Abs(scriptPath)
	a.cdRipSidecar = NewNodeSidecar(absPath)

	a.cdRipSidecar.SetEventCallback(func(eventType string, payload json.RawMessage) {
		fmt.Printf("[Wails] CD-RIP Event: %s\n", eventType)
		var data interface{}
		json.Unmarshal(payload, &data)
		runtime.EventsEmit(a.ctx, eventType, data)
	})
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
	fmt.Println("[Wails] LoadPlayCounts called")
	counts, _ := stores.Load("playcounts")
	if counts == nil {
		counts = make(map[string]interface{})
	}
	runtime.EventsEmit(a.ctx, "play-counts-updated", counts)
}

// IncrementPlayCount increments the play count for a song
func (a *App) IncrementPlayCount(song map[string]interface{}) {
	fmt.Printf("[Wails] IncrementPlayCount called for: %v\n", song["title"])
	path, ok := song["path"].(string)
	if !ok {
		return
	}

	counts, _ := stores.Load("playcounts")
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
	stores.Save("playcounts", countsMap)

	runtime.EventsEmit(a.ctx, "play-counts-updated", countsMap)
}

// SongFinished handles the end of a song, updating analysis score
func (a *App) SongFinished(song map[string]interface{}) {
	fmt.Printf("[Wails] SongFinished called for: %v\n", song["title"])
	id, ok := song["id"].(string)
	if !ok {
		return
	}

	data, _ := stores.Load("analysed-queue")
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
			stores.Save("analysed-queue", analysedData)
		}
	}
}

func (a *App) SongSkipped(data map[string]interface{}) {
	// Electron版の ipcMain.on(IPC_CHANNELS.SEND.SONG_SKIPPED, ...) の移植
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
		scoreIncrement = 5 // Instant skip
	} else if playbackPercentage <= 10 {
		scoreIncrement = 3 // Strong dislike
	} else if playbackPercentage <= 50 {
		scoreIncrement = 1 // Moderate dislike
	}

	if scoreIncrement > 0 {
		dislikeData, _ := stores.Load("analysed-queue")
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
		stores.Save("analysed-queue", dislikeMap)
	}
}

// RequestPlaylistsWithArtwork loads playlists and emits an event
func (a *App) RequestPlaylistsWithArtwork() {
	fmt.Println("[Wails] RequestPlaylistsWithArtwork called")

	// Get playlist names from file system
	playlistNames, err := GetAllPlaylists()
	if err != nil {
		fmt.Printf("[Wails] Error getting playlists: %v\n", err)
		runtime.EventsEmit(a.ctx, "playlists-updated", []interface{}{})
		return
	}

	// Load library to get artwork info
	library, _ := stores.Load("library")
	var librarySongs []interface{}
	if library != nil {
		librarySongs = library.([]interface{})
	}

	// Create a map from path to artwork
	pathToArtwork := make(map[string]string)
	for _, s := range librarySongs {
		song := s.(map[string]interface{})
		if path, ok := song["path"].(string); ok {
			if artwork, ok := song["artwork"].(string); ok && artwork != "" {
				pathToArtwork[path] = artwork
			}
		}
	}

	// Build playlist objects with artworks
	var playlists []interface{}
	for _, name := range playlistNames {
		songPaths, _ := GetPlaylistSongs(name)

		// Get first 4 unique artworks for collage
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
	fmt.Println("[Wails] GetSituationPlaylists called")

	result := make(map[string]interface{})

	// Load library
	library, _ := stores.Load("library")
	if library == nil {
		return result, nil
	}

	songs := library.([]interface{})
	if len(songs) == 0 {
		return result, nil
	}

	// 1. Recently Added (最近追加した曲) - 最新の20曲
	recentSongs := make([]interface{}, 0)
	maxRecent := 20
	if len(songs) < maxRecent {
		maxRecent = len(songs)
	}
	// 最後に追加された曲を取得（配列の後ろから）
	for i := len(songs) - 1; i >= len(songs)-maxRecent && i >= 0; i-- {
		recentSongs = append(recentSongs, songs[i])
	}
	if len(recentSongs) > 0 {
		result["recently_added"] = map[string]interface{}{
			"name":  "最近追加した曲",
			"songs": recentSongs,
		}
	}

	// 2. Most Played (よく聴く曲) - play-counts データを使用
	playCounts, _ := stores.Load("playcounts")
	if playCounts != nil {
		countsMap := playCounts.(map[string]interface{})
		if len(countsMap) > 0 {
			// 再生回数でソートした曲を取得
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

			// 簡易的なソート（降順）
			for i := 0; i < len(songsWithCounts)-1; i++ {
				for j := i + 1; j < len(songsWithCounts); j++ {
					if songsWithCounts[j].count > songsWithCounts[i].count {
						songsWithCounts[i], songsWithCounts[j] = songsWithCounts[j], songsWithCounts[i]
					}
				}
			}

			// 上位20曲を取得
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

	// 3. Random Pick (ランダムピック) - ランダムに20曲選択
	if len(songs) >= 5 {
		randomSongs := make([]interface{}, 0)
		maxRandom := 20
		if len(songs) < maxRandom {
			maxRandom = len(songs)
		}
		// シンプルな疑似ランダム選択（現在時刻ベース）
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

// --- CD-RIP Methods ---

func (a *App) ensureCDSidecar() error {
	if !a.cdRipSidecar.IsRunning() {
		if err := a.cdRipSidecar.Start(); err != nil {
			return err
		}
		// Init sidecar
		payload := map[string]string{
			"userDataPath": config.GetUserDataPath(),
		}
		_, err := a.cdRipSidecar.Invoke("init", payload)
		return err
	}
	return nil
}

func (a *App) CDScan() (interface{}, error) {
	if err := a.ensureCDSidecar(); err != nil {
		return nil, err
	}
	resp, err := a.cdRipSidecar.Invoke("scan", nil)
	if err != nil {
		return nil, err
	}
	var result interface{}
	json.Unmarshal(resp.Payload, &result)
	return result, nil
}

func (a *App) CDSearchTOC(tracks interface{}) (interface{}, error) {
	if err := a.ensureCDSidecar(); err != nil {
		return nil, err
	}
	resp, err := a.cdRipSidecar.Invoke("search-toc", tracks)
	if err != nil {
		return nil, err
	}
	var result interface{}
	json.Unmarshal(resp.Payload, &result)
	return result, nil
}

func (a *App) CDSearchText(query string) (interface{}, error) {
	if err := a.ensureCDSidecar(); err != nil {
		return nil, err
	}
	resp, err := a.cdRipSidecar.Invoke("search-text", query)
	if err != nil {
		return nil, err
	}
	var result interface{}
	json.Unmarshal(resp.Payload, &result)
	return result, nil
}

func (a *App) CDApplyMetadata(tracks interface{}, releaseId string) (interface{}, error) {
	if err := a.ensureCDSidecar(); err != nil {
		return nil, err
	}
	payload := map[string]interface{}{
		"tracks":    tracks,
		"releaseId": releaseId,
	}
	resp, err := a.cdRipSidecar.Invoke("apply-metadata", payload)
	if err != nil {
		return nil, err
	}
	var result interface{}
	json.Unmarshal(resp.Payload, &result)
	return result, nil
}

func (a *App) CDStartRip(tracks interface{}, options interface{}) (interface{}, error) {
	if err := a.ensureCDSidecar(); err != nil {
		return nil, err
	}

	// 便宜上ライブラリパスを取得して渡す
	settings, _ := stores.Load("settings")
	libraryPath := ""
	if settings != nil {
		if sMap, ok := settings.(map[string]interface{}); ok {
			if lp, ok := sMap["libraryPath"].(string); ok {
				libraryPath = lp
			}
		}
	}
	if libraryPath == "" {
		// Fallback to Music folder
		home, _ := os.UserHomeDir()
		libraryPath = filepath.Join(home, "Music")
	}

	payload := map[string]interface{}{
		"tracksToRip": tracks,
		"options":     options,
		"libraryPath": libraryPath,
	}
	resp, err := a.cdRipSidecar.Invoke("start-rip", payload)
	if err != nil {
		return nil, err
	}
	var result interface{}
	json.Unmarshal(resp.Payload, &result)
	return result, nil
}
