package scanner

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dhowden/tag"
)

// Song represents the metadata of a music file
type Song struct {
	Path        string      `json:"path"`
	Title       string      `json:"title"`
	Artist      string      `json:"artist"`
	Album       string      `json:"album"`
	AlbumArtist string      `json:"albumartist"`
	Year        int         `json:"year"`
	Genre       string      `json:"genre"`
	Duration    float64     `json:"duration"`
	TrackNumber int         `json:"trackNumber"`
	DiscNumber  int         `json:"discNumber"`
	FileSize    int64       `json:"fileSize"`
	FileType    string      `json:"fileType"`
	SampleRate  int         `json:"sampleRate,omitempty"`
	Artwork     interface{} `json:"artwork,omitempty"`
}

var supportedExtensions = map[string]bool{
	".mp3":  true,
	".flac": true,
	".wav":  true,
	".ogg":  true,
	".m4a":  true,
	".mp4":  true,
}

// ScanResult holds the result of a scan operation
type ScanResult struct {
	Songs []Song `json:"songs"`
	Count int    `json:"count"`
	Time  int64  `json:"timeMs"`
}

// ScanLibrary scans the given directories for music files
func ScanLibrary(paths []string, artworksDir string) ScanResult {
	start := time.Now()
	var wg sync.WaitGroup
	songsChan := make(chan Song, 100)

	for _, rootPath := range paths {
		wg.Add(1)
		go func(p string) {
			defer wg.Done()
			walkDirectory(p, &wg, songsChan, artworksDir)
		}(rootPath)
	}

	go func() {
		wg.Wait()
		close(songsChan)
	}()

	var songs []Song
	for song := range songsChan {
		songs = append(songs, song)
	}

	elapsed := time.Since(start).Milliseconds()
	return ScanResult{
		Songs: songs,
		Count: len(songs),
		Time:  elapsed,
	}
}

func walkDirectory(root string, wg *sync.WaitGroup, songsChan chan<- Song, artworksDir string) {
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if supportedExtensions[ext] {
			wg.Add(1)
			go func(filePath string, info os.FileInfo) {
				defer wg.Done()
				song := parseFile(filePath, info, artworksDir)
				songsChan <- song
			}(path, nil)
		}
		return nil
	})
}

func parseFile(path string, info os.FileInfo, artworksDir string) Song {
	f, err := os.Open(path)
	if err != nil {
		return Song{Path: path, Title: filepath.Base(path)}
	}
	defer f.Close()

	fileInfo, _ := f.Stat()
	size := int64(0)
	if fileInfo != nil {
		size = fileInfo.Size()
	}

	m, err := tag.ReadFrom(f)
	if err != nil {
		return Song{
			Path:     path,
			Title:    filepath.Base(path),
			FileSize: size,
			FileType: strings.ToLower(filepath.Ext(path)),
		}
	}

	title := m.Title()
	if title == "" {
		title = filepath.Base(path)
	}
	artist := m.Artist()
	if artist == "" {
		artist = "Unknown Artist"
	}
	album := m.Album()
	if album == "" {
		album = "Unknown Album"
	}

	track, _ := m.Track()
	disc, _ := m.Disc()
	year := m.Year()
	genre := m.Genre()

	song := Song{
		Path:        path,
		Title:       title,
		Artist:      artist,
		Album:       album,
		AlbumArtist: m.AlbumArtist(),
		Year:        year,
		Genre:       genre,
		TrackNumber: track,
		DiscNumber:  disc,
		FileSize:    size,
		FileType:    strings.ToLower(filepath.Ext(path)),
	}

	if artworksDir != "" {
		if artwork, err := extractAndSaveArtwork(path, artworksDir); err == nil {
			song.Artwork = artwork
		}
	}

	return song
}
