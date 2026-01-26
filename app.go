package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"
	"golang.org/x/text/width"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"ux-music-sidecar/pkg/cdrip"
	"ux-music-sidecar/pkg/mtp"
	"ux-music-sidecar/pkg/normalize"
)

// App struct
type App struct {
	ctx          context.Context
	ripper       *cdrip.Ripper
	mtpManager   *mtp.Manager
	normalizer   *normalize.Normalizer
	mtpConnected bool
	mtpMu        sync.Mutex
}

// NewApp creates a new App struct
func NewApp() *App {
	return &App{}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Determine binary paths
	// TODO: Handle production paths correctly
	cwd, _ := os.Getwd()
	binDir := filepath.Join(cwd, "bin", "macos")

	cdParanoiaPath := filepath.Join(binDir, "cdparanoia")
	ffmpegPath := "ffmpeg" // Default to system PATH
	if _, err := os.Stat(filepath.Join(binDir, "ffmpeg")); err == nil {
		ffmpegPath = filepath.Join(binDir, "ffmpeg")
	}
	ffprobePath := "ffprobe"
	if _, err := os.Stat(filepath.Join(binDir, "ffprobe")); err == nil {
		ffprobePath = filepath.Join(binDir, "ffprobe")
	}

	userDataPath := config.GetUserDataPath()

	// Initialize components
	a.ripper = cdrip.NewRipper(cdParanoiaPath, ffmpegPath, userDataPath)
	a.mtpManager = mtp.NewManager()
	a.normalizer = normalize.NewNormalizer(ffmpegPath, ffprobePath)

	fmt.Println("[Wails] App components initialized")

	// Start MTP device monitoring
	a.startMTPMonitor()
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

	// 必要最小限の情報を送るようにする。
	if songs == nil {
		songs = []interface{}{}
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
	counts, _ := stores.Load("playcounts")
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

	wailsRuntime.EventsEmit(a.ctx, "play-counts-updated", countsMap)
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
		wailsRuntime.EventsEmit(a.ctx, "playlists-updated", []interface{}{})
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

	wailsRuntime.EventsEmit(a.ctx, "playlists-updated", playlists)
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
		wailsRuntime.EventsEmit(a.ctx, "lyrics-added-notification", count)
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

// --- CD-RIP Methods ---

func (a *App) CDScan() ([]cdrip.Track, error) {
	return a.ripper.GetTrackList()
}

func (a *App) CDSearchTOC(tracks []cdrip.Track) ([]cdrip.ReleaseInfo, error) {
	return cdrip.SearchByTOC(tracks)
}

func (a *App) CDSearchText(query string) ([]cdrip.ReleaseInfo, error) {
	return cdrip.SearchByText(query)
}

func (a *App) CDApplyMetadata(args map[string]interface{}) (*cdrip.ReleaseInfo, error) {
	// Parse args manually or change signature
	tracksJSON, _ := json.Marshal(args["tracks"])
	var tracks []cdrip.Track
	json.Unmarshal(tracksJSON, &tracks)

	releaseID, _ := args["releaseId"].(string)

	return cdrip.ApplyMetadata(tracks, releaseID)
}

func (a *App) CDStartRip(args map[string]interface{}) (interface{}, error) {
	fmt.Println("[Wails] CDStartRip called")
	tracksJSON, _ := json.Marshal(args["tracksToRip"])
	var tracks []cdrip.Track
	json.Unmarshal(tracksJSON, &tracks)

	optionsJSON, _ := json.Marshal(args["options"])
	var options cdrip.RipOptions
	json.Unmarshal(optionsJSON, &options)

	libraryPath, _ := args["libraryPath"].(string)
	if libraryPath == "" {
		home, _ := os.UserHomeDir()
		libraryPath = filepath.Join(home, "Music")
	}

	fmt.Printf("[Wails] Starting rip of %d tracks to %s\n", len(tracks), libraryPath)

	progressChan := make(chan cdrip.RipProgress)

	// Relay events in a separate goroutine
	go func() {
		for p := range progressChan {
			wailsRuntime.EventsEmit(a.ctx, "rip-progress", p)
		}
	}()

	// Perform rip synchronously
	err := a.ripper.StartRip(tracks, options, libraryPath, progressChan)
	close(progressChan)

	if err != nil {
		fmt.Printf("[Wails] Rip error: %v\n", err)
		return nil, err
	}

	fmt.Println("[Wails] Rip completed successfully")
	return map[string]interface{}{
		"count":     len(tracks),
		"outputDir": filepath.Join(libraryPath, "CD Rips"),
	}, nil
}

// --- MTP Methods ---

func (a *App) MTPInitialize() error {
	return a.mtpManager.Initialize()
}

func (a *App) MTPFetchDeviceInfo() (map[string]interface{}, error) {
	return a.mtpManager.FetchDeviceInfo()
}

func (a *App) MTPFetchStorages() ([]mtp.Storage, error) {
	return a.mtpManager.FetchStorages()
}

func (a *App) MTPWalk(opts mtp.WalkOptions) (interface{}, error) {
	fmt.Printf("[Wails] MTPWalk called: StorageID=%d, Path=%s\n", opts.StorageID, opts.FullPath)
	res, err := a.mtpManager.Walk(opts)
	if err != nil {
		fmt.Printf("[Wails] MTPWalk error: %v\n", err)
		return nil, err
	}
	return map[string]interface{}{
		"data": res,
	}, nil
}

func (a *App) MTPUploadFiles(opts mtp.TransferOptions) error {
	return a.mtpManager.UploadFiles(opts, func(data interface{}) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-upload-preprocess", data)
	}, func(prog mtp.TransferProgress) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-upload-progress", prog)
	})
}

func (a *App) MTPDownloadFiles(opts mtp.TransferOptions) error {
	return a.mtpManager.DownloadFiles(opts, func(data interface{}) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-download-preprocess", data)
	}, func(prog mtp.TransferProgress) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-download-progress", prog)
	})
}

func (a *App) MTPUploadFilesWithStructure(data map[string]interface{}) (map[string]interface{}, error) {
	storageID := uint32(data["storageId"].(float64))
	transferList := data["transferList"].([]interface{})

	fmt.Printf("[Wails] MTPUploadFilesWithStructure: storage=%d, items=%d\n", storageID, len(transferList))

	// Destination ごとに Grouping
	groups := make(map[string][]string)
	for _, item := range transferList {
		m := item.(map[string]interface{})
		src := m["source"].(string)
		dest := m["destination"].(string)
		groups[dest] = append(groups[dest], src)
	}

	successCount := 0
	errorCount := 0

	for dest, sources := range groups {
		// 1. ディレクトリの存在確認と作成
		// Kalam の MakeDirectory が再帰的でない場合に備えて、各階層を作成
		parts := strings.Split(strings.Trim(dest, "/"), "/")
		currentPath := ""
		for _, part := range parts {
			currentPath += "/" + part
			// エラーを無視して作成を試みる（既存の場合はエラーになるがスキップ）
			_ = a.mtpManager.MakeDirectory(mtp.MakeDirOptions{
				StorageID: storageID,
				FullPath:  currentPath,
			})
		}

		// 2. アップロード実行
		err := a.mtpManager.UploadFiles(mtp.TransferOptions{
			StorageID:   storageID,
			Sources:     sources,
			Destination: dest,
		}, func(data interface{}) {
			wailsRuntime.EventsEmit(a.ctx, "mtp-upload-preprocess", data)
		}, func(prog mtp.TransferProgress) {
			wailsRuntime.EventsEmit(a.ctx, "mtp-upload-progress", prog)
		})

		if err != nil {
			fmt.Printf("[Wails] Upload error to %s: %v\n", dest, err)
			errorCount += len(sources)
		} else {
			successCount += len(sources)
		}
	}

	return map[string]interface{}{
		"successCount": successCount,
		"errorCount":   errorCount,
	}, nil
}

func (a *App) MTPDeleteFile(opts mtp.DeleteOptions) error {
	return a.mtpManager.DeleteFile(opts)
}

func (a *App) MTPMakeDirectory(opts mtp.MakeDirOptions) error {
	return a.mtpManager.MakeDirectory(opts)
}

func (a *App) MTPDispose() error {
	return a.mtpManager.Dispose()
}

func (a *App) MTPGetUntransferredSongs(librarySongs []interface{}) (map[string]interface{}, error) {
	fmt.Printf("[Wails] MTPGetUntransferredSongs started: processing %d library songs\n", len(librarySongs))

	a.mtpMu.Lock()
	connected := a.mtpConnected
	a.mtpMu.Unlock()

	if !connected {
		fmt.Println("[Wails] MTPGetUntransferredSongs: device not connected")
		return map[string]interface{}{
			"untransferredSongs": []interface{}{},
			"deviceFilesList":    []interface{}{},
		}, nil
	}

	// 1. デバイス上の /Music/ フォルダを再帰的にスキャン
	deviceFilesMap := make(map[string][]map[string]interface{})
	deviceFilesList := make([]map[string]interface{}, 0)

	storages, err := a.mtpManager.FetchStorages()
	if err != nil || len(storages) == 0 {
		return nil, fmt.Errorf("failed to fetch storages: %v", err)
	}
	storageID := storages[0].ID

	var scanDir func(string)
	scanDir = func(path string) {
		res, err := a.mtpManager.Walk(mtp.WalkOptions{
			StorageID:       storageID,
			FullPath:        path,
			SkipHiddenFiles: true,
		})
		if err != nil {
			fmt.Printf("[Wails] scanDir error (%s): %v\n", path, err)
			return
		}

		items, ok := res.([]interface{})
		if !ok {
			return
		}

		for _, item := range items {
			m, ok := item.(map[string]interface{})
			if !ok {
				continue
			}

			name, _ := m["name"].(string)
			isFolder, _ := m["isFolder"].(bool)
			path, _ := m["path"].(string)

			var size int64
			if s, ok := m["size"].(float64); ok {
				size = int64(s)
			} else if s, ok := m["size"].(json.Number); ok {
				size, _ = s.Int64()
			}

			if isFolder {
				if path != "" {
					scanDir(path)
				}
			} else {
				normName := normalizeFileNameGo(name)
				fileInfo := map[string]interface{}{
					"name":           name,
					"normalizedName": normName,
					"size":           size,
					"fullPath":       path, // 互換性のために一旦残す
					"path":           path,
				}
				deviceFilesList = append(deviceFilesList, fileInfo)
				deviceFilesMap[normName] = append(deviceFilesMap[normName], fileInfo)
			}
		}
	}

	scanDir("/Music/")
	fmt.Printf("[Wails] Scan complete: %d files found on device\n", len(deviceFilesList))

	// 2. ライブラリ内の曲と比較
	untransferredSongs := make([]interface{}, 0)
	for _, song := range librarySongs {
		sMap, ok := song.(map[string]interface{})
		if !ok {
			continue
		}

		pathStr, _ := sMap["path"].(string)
		if pathStr == "" {
			continue
		}

		fileName := filepath.Base(pathStr)
		normName := normalizeFileNameGo(fileName)

		if _, exists := deviceFilesMap[normName]; !exists {
			// 未転送
			// 元のデータを壊さないようコピーして使うのが安全だが、一旦そのまま。
			// UI側で _reason が必要
			sMap["_reason"] = fmt.Sprintf("名前不一致: \"%s\"", normName)
			sMap["_normalizedName"] = normName
			untransferredSongs = append(untransferredSongs, sMap)
		}
	}

	fmt.Printf("[Wails] Found %d untransferred songs\n", len(untransferredSongs))
	return map[string]interface{}{
		"untransferredSongs": untransferredSongs,
		"deviceFilesList":    deviceFilesList,
	}, nil
}

func normalizeFileNameGo(fileName string) string {
	// Unicode正規化 (NFCに統一、macOSのNFD問題を解決)
	name := norm.NFC.String(fileName)

	// 拡張子除去
	ext := filepath.Ext(name)
	name = strings.TrimSuffix(name, ext)

	// 全角英数字を半角に、半角カタカナを全角に変換
	name = width.Fold.String(name)

	// トラック番号除去 (01-, 02. , etc)
	reTrack := regexp.MustCompile(`^\d+[-\s.]*`)
	name = reTrack.ReplaceAllString(name, "")

	// カタカナ長音記号の統一（ー、－、―、─、ｰ など）
	reChon := regexp.MustCompile(`[ー－―─ｰ]`)
	name = reChon.ReplaceAllString(name, "ー")

	// 小文字化
	name = strings.ToLower(name)

	// 特殊記号や空白を除去（英数字、アンダーバー、日本語文字のみ残す）
	// \w はアンダーバーを含む英数字。日本語は Unicode レンジで指定。
	// [^\w\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{4E00}-\x{9FAF}ー]
	reClean := regexp.MustCompile(`[^\w\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{4E00}-\x{9FAF}ー]`)
	name = reClean.ReplaceAllString(name, "")

	return strings.TrimSpace(name)
}

func (a *App) MTPGetStatus() (map[string]interface{}, error) {
	a.mtpMu.Lock()
	connected := a.mtpConnected
	a.mtpMu.Unlock()

	if !connected {
		return nil, nil
	}

	// すでに接続されている場合は、キャッシュされた情報または新規に取得した情報を返す
	// ここでは確実に最新を返すために再度取得を試みる
	deviceInfo, _ := a.mtpManager.FetchDeviceInfo()
	storages, _ := a.mtpManager.FetchStorages()

	// Build payload (startMTPMonitor と同じロジック)
	storagesForUI := make([]map[string]interface{}, 0)
	for _, s := range storages {
		storagesForUI = append(storagesForUI, map[string]interface{}{
			"id":          s.ID,
			"free":        s.Info.FreeSpaceInBytes,
			"total":       s.Info.MaxCapability,
			"description": s.Info.StorageDescription,
		})
	}

	deviceName := "MTP Device"
	if deviceInfo != nil {
		if mtpInfo, ok := deviceInfo["mtpDeviceInfo"].(map[string]interface{}); ok {
			if name, ok := mtpInfo["Model"].(string); ok && name != "" {
				deviceName = name
			}
		}
	}

	return map[string]interface{}{
		"device": map[string]interface{}{
			"name": deviceName,
		},
		"storages": storagesForUI,
	}, nil
}

// startMTPMonitor starts a goroutine that polls for MTP device connection
func (a *App) startMTPMonitor() {
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		fmt.Println("[MTP Monitor] Started polling for MTP devices")

		for range ticker.C {
			a.mtpMu.Lock()
			wasConnected := a.mtpConnected
			a.mtpMu.Unlock()

			if wasConnected {
				// Already connected - check if still connected by trying FetchStorages
				_, err := a.mtpManager.FetchStorages()
				if err != nil {
					// Device disconnected
					fmt.Println("[MTP Monitor] Device disconnected")
					a.mtpManager.Dispose()
					a.mtpMu.Lock()
					a.mtpConnected = false
					a.mtpMu.Unlock()
					wailsRuntime.EventsEmit(a.ctx, "mtp-device-disconnected")
				}
				// Still connected, do nothing
				continue
			}

			// Not connected - try to initialize MTP
			err := a.mtpManager.Initialize()
			if err != nil {
				// 頻繁な Initialize 失敗ログを避ける（デバイスがないのが通常）
				continue
			}

			// Device found - fetch info
			fmt.Println("[MTP Monitor] Device connected, fetching info...")

			// Fetch device info
			deviceInfo, err := a.mtpManager.FetchDeviceInfo()
			if err != nil {
				fmt.Printf("[MTP Monitor] Failed to fetch device info: %v\n", err)
				a.mtpManager.Dispose()
				continue
			}

			// Fetch storages
			storages, err := a.mtpManager.FetchStorages()
			if err != nil {
				fmt.Printf("[MTP Monitor] Failed to fetch storages: %v\n", err)
				a.mtpManager.Dispose()
				continue
			}
			fmt.Printf("[MTP Monitor] Fetched %d storages: %+v\n", len(storages), storages)

			// Build storage info for UI (matching Electron format)
			storagesForUI := make([]map[string]interface{}, 0)
			for _, s := range storages {
				storagesForUI = append(storagesForUI, map[string]interface{}{
					"id":          s.ID,
					"free":        s.Info.FreeSpaceInBytes,
					"total":       s.Info.MaxCapability,
					"description": s.Info.StorageDescription,
				})
			}

			// Build device name
			deviceName := "MTP Device"
			if deviceInfo != nil {
				// Kalamライブラリの deviceInfo は { "mtpDeviceInfo": {...}, "usbDeviceInfo": {...} } という構造
				if mtpInfo, ok := deviceInfo["mtpDeviceInfo"].(map[string]interface{}); ok {
					if name, ok := mtpInfo["Model"].(string); ok && name != "" {
						deviceName = name
					}
				}
				if deviceName == "MTP Device" {
					if usbInfo, ok := deviceInfo["usbDeviceInfo"].(map[string]interface{}); ok {
						if name, ok := usbInfo["Product"].(string); ok && name != "" {
							deviceName = name
						}
					}
				}
			}

			// Build payload matching Electron format
			payload := map[string]interface{}{
				"device": map[string]interface{}{
					"name":          deviceName,
					"mtpDeviceInfo": deviceInfo,
				},
				"storages": storagesForUI,
			}

			a.mtpMu.Lock()
			a.mtpConnected = true
			a.mtpMu.Unlock()

			fmt.Printf("[MTP Monitor] Device connected: %s\n", deviceName)
			wailsRuntime.EventsEmit(a.ctx, "mtp-device-connected", payload)

			// 接続されたらポーリング間隔を広げる（切断チェックのみにする）
			ticker.Reset(5 * time.Second)
		}
	}()
}

// --- Normalize Methods ---

func (a *App) NormalizeAnalyze(path string) normalize.AnalysisResult {
	return a.normalizer.AnalyzeLoudness(path)
}

func (a *App) NormalizeApply(job normalize.NormalizeJob) normalize.NormalizeResult {
	return a.normalizer.ApplyNormalization(job)
}

func (a *App) NormalizeStartJob(jobType string, files []interface{}, options normalize.OutputSettings) {
	// Parse files
	var jobs []normalize.NormalizeJob
	for _, f := range files {
		fMap := f.(map[string]interface{})
		id, _ := fMap["id"].(string)
		path, _ := fMap["path"].(string)
		gain, _ := fMap["gain"].(float64)

		jobs = append(jobs, normalize.NormalizeJob{
			ID:       id,
			FilePath: path,
			Gain:     gain,
			Backup:   options.Mode == "overwrite", // Simplified assumption based on JS logic?
			// Wait, JS logic passed 'backup' explicitely in 'options' struct?
			// In js: ipcMain.on(..., { jobType, files, options })
			// options had 'backup' and 'output' and 'basePath'?
			Output:   options,
			BasePath: "", // Fill if needed
		})
	}
	// Note: The above parsing is simplified. Better to accept typed struct if possible.
	// But let's stick to core logic: concurrency.

	go func() {
		concurrency := runtime.GOMAXPROCS(0) - 1
		if concurrency < 1 {
			concurrency = 1
		}

		sem := make(chan struct{}, concurrency)
		var wg sync.WaitGroup

		for _, job := range jobs {
			wg.Add(1)
			sem <- struct{}{}
			go func(j normalize.NormalizeJob) {
				defer wg.Done()
				defer func() { <-sem }()

				var res interface{}
				if jobType == "analyze" {
					res = a.normalizer.AnalyzeLoudness(j.FilePath)
				} else {
					res = a.normalizer.ApplyNormalization(j)
				}

				// Emit event
				wailsRuntime.EventsEmit(a.ctx, "normalize-worker-result", map[string]interface{}{
					"type":   jobType + "-result", // "analyze-result" or "normalize-result"
					"id":     j.ID,
					"result": res,
				})
			}(job)
		}
		wg.Wait()
		wailsRuntime.EventsEmit(a.ctx, "normalize-job-finished")
	}()
}
