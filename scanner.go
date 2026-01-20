package main

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
	Path        string  `json:"path"`
	Title       string  `json:"title"`
	Artist      string  `json:"artist"`
	Album       string  `json:"album"`
	AlbumArtist string  `json:"albumartist"`
	Year        int     `json:"year"`
	Genre       string  `json:"genre"`
	Duration    float64 `json:"duration"`
	TrackNumber int     `json:"trackNumber"`
	DiscNumber  int     `json:"discNumber"`
	FileSize    int64   `json:"fileSize"`
	FileType    string  `json:"fileType"`
	SampleRate  int     `json:"sampleRate,omitempty"` // dhowden/tag では取れない場合があるが枠だけ用意
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
	Time  int64  `json:"timeMs"` // Processing time in milliseconds
}

// ScanLibrary scans the given directories for music files
func ScanLibrary(paths []string) ScanResult {
	start := time.Now()
	var wg sync.WaitGroup
	songsChan := make(chan Song, 100) // Buffer to prevent blocking

	// 1. Walk files
	for _, rootPath := range paths {
		wg.Add(1)
		go func(p string) {
			defer wg.Done()
			walkDirectory(p, &wg, songsChan)
		}(rootPath)
	}

	// 2. Close channel when all walkers are done
	go func() {
		wg.Wait()
		close(songsChan)
	}()

	// 3. Collect results
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

func walkDirectory(root string, wg *sync.WaitGroup, songsChan chan<- Song) {
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if supportedExtensions[ext] {
			// Process file in a separate goroutine (worker pool assumption or raw goroutine)
			// For simplicity and assuming IO bound, raw goroutines are usually fine for filesystem scan on modern OS
			wg.Add(1)
			go func(filePath string, info os.FileInfo) {
				defer wg.Done()
				song := parseFile(filePath, info)
				songsChan <- song
			}(path, nil) // passing nil for info to let parseFile stat if needed, or we can get info from d.Info()
		}
		return nil
	})
}

func parseFile(path string, info os.FileInfo) Song {
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
		// タグが読めない場合はファイル名などをフォールバックとして使う
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

	// dhowden/tag does not typically provide duration directly for all formats easily without full Parse
	// For MVP, we might set duration to 0 or use another lib if critical.
	// Note: Wails移行時には `tcolgate/mp3` や ffmpeg binding などで正確なDurationを取る必要がある。
	// 今回は「高速スキャン」優先のため、Duration取得が重いライブラリは避ける方針とするか、
	// Electron側でDurationがないものだけ補完するハイブリッド戦略も取れる。
	// 一旦、tagライブラリで取れる範囲のメタデータのみを返す。

	return Song{
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
		// Duration: 0, // JS側でmetadata取得済みのDBがあればそれを使う等の工夫が必要
	}
}
