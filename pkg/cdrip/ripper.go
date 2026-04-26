package cdrip

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Ripper manages CD ripping operations
type Ripper struct {
	CDParanoiaPath string
	FFmpegPath     string
	UserDataPath   string
}

var resolvedBinaryPaths sync.Map

// NewRipper creates a new Ripper instance
func NewRipper(cdParanoiaPath, ffmpegPath, userDataPath string) *Ripper {
	return &Ripper{
		CDParanoiaPath: cdParanoiaPath,
		FFmpegPath:     ffmpegPath,
		UserDataPath:   userDataPath,
	}
}

func isExecutable(path string) bool {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return false
	}
	info, err := os.Stat(trimmed)
	if err != nil || info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

func resolveBinaryPath(name, explicitPath string) (string, error) {
	if cached, ok := resolvedBinaryPaths.Load(name); ok {
		if path, ok := cached.(string); ok && isExecutable(path) {
			return path, nil
		}
		resolvedBinaryPaths.Delete(name)
	}

	if isExecutable(explicitPath) {
		resolvedBinaryPaths.Store(name, explicitPath)
		return explicitPath, nil
	}

	if path, err := exec.LookPath(name); err == nil && isExecutable(path) {
		resolvedBinaryPaths.Store(name, path)
		return path, nil
	}

	binaryName := name
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(name), ".exe") {
		binaryName = name + ".exe"
	}

	var candidates []string
	if execPath, err := os.Executable(); err == nil {
		execDir := filepath.Dir(execPath)
		candidates = append(candidates,
			// production: UX-Music.app/Contents/Resources/bin/
			filepath.Clean(filepath.Join(execDir, "..", "Resources", "bin", binaryName)),
			filepath.Clean(filepath.Join(execDir, "..", "Resources", binaryName)),
			// wails dev: project root bin/macos/
			filepath.Clean(filepath.Join(execDir, "bin", "macos", binaryName)),
			filepath.Clean(filepath.Join(execDir, "..", "bin", "macos", binaryName)),
			filepath.Clean(filepath.Join(execDir, "..", "..", "bin", "macos", binaryName)),
		)
	}
	candidates = append(candidates,
		filepath.Join("/opt/homebrew/bin", binaryName),
		filepath.Join("/usr/local/bin", binaryName),
		filepath.Join("/opt/local/bin", binaryName),
		filepath.Join("/usr/bin", binaryName),
		filepath.Join("/bin", binaryName),
	)

	for _, candidate := range candidates {
		if isExecutable(candidate) {
			resolvedBinaryPaths.Store(name, candidate)
			fmt.Printf("[CDRip] binary resolved: %s -> %s\n", name, candidate)
			return candidate, nil
		}
	}

	return "", fmt.Errorf("%s が見つかりません (PATH=%q)", name, os.Getenv("PATH"))
}

// OutputDir returns the directory where ripped files are saved.
func (r *Ripper) OutputDir(libraryPath string) string {
	return filepath.Join(libraryPath, "CD Rips")
}

// GetTrackList scans the CD for tracks
func (r *Ripper) GetTrackList() ([]Track, error) {
	cdparanoiaPath, err := resolveBinaryPath("cdparanoia", r.CDParanoiaPath)
	if err != nil {
		return nil, fmt.Errorf("failed to run cdparanoia: %w", err)
	}

	cmd := exec.Command(cdparanoiaPath, "-Q")
	var out bytes.Buffer
	cmd.Stderr = &out
	cmd.Stdout = &out

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("failed to run cdparanoia: %w", err)
	}

	return parseTrackList(out.String()), nil
}

func parseTrackList(output string) []Track {
	var tracks []Track
	scanner := bufio.NewScanner(strings.NewReader(output))
	// Regex matches lines like: "  1. 12345" where 1 is track number, 12345 is sectors
	re := regexp.MustCompile(`^\s*(\d+)\.\s+(\d+)`)

	for scanner.Scan() {
		line := scanner.Text()
		matches := re.FindStringSubmatch(line)
		if len(matches) == 3 {
			num, _ := strconv.Atoi(matches[1])
			sectors, _ := strconv.Atoi(matches[2])
			tracks = append(tracks, Track{
				Number:  num,
				Title:   fmt.Sprintf("Track %d", num),
				Artist:  "Unknown Artist",
				Sectors: sectors,
			})
		}
	}
	return tracks
}

// StartRip Rips selected tracks
// progressChan is used to report progress. It can be nil.
func (r *Ripper) StartRip(tracks []Track, options RipOptions, libraryPath string, progressChan chan<- RipProgress) error {
	outputDir := filepath.Join(libraryPath, "CD Rips")
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return err
	}

	// Download artwork if needed
	var artworkPath string
	if options.ArtworkURL != "" {
		artworkPath = filepath.Join(r.UserDataPath, fmt.Sprintf("temp_artwork_%d.jpg", time.Now().UnixNano()))
		if err := downloadFile(options.ArtworkURL, artworkPath); err != nil {
			fmt.Printf("Failed to download artwork: %v\n", err)
			artworkPath = "" // Continue without artwork
		} else {
			defer os.Remove(artworkPath)
		}
	}

	for _, track := range tracks {
		fmt.Printf("[Ripper] Starting track %d\n", track.Number)
		if progressChan != nil {
			progressChan <- RipProgress{TrackNumber: track.Number, Status: "ripping", Percent: 0}
		}

		err := r.ripAndConvert(track, outputDir, options, artworkPath, progressChan)

		if err != nil {
			fmt.Printf("[Ripper] Error processing track %d: %v\n", track.Number, err)
			if progressChan != nil {
				progressChan <- RipProgress{TrackNumber: track.Number, Status: "error", Error: err.Error()}
			}
			return err
		}

		fmt.Printf("[Ripper] Completed track %d\n", track.Number)
		if progressChan != nil {
			progressChan <- RipProgress{TrackNumber: track.Number, Status: "completed", Percent: 100}
		}
	}

	return nil
}

func (r *Ripper) ripAndConvert(track Track, outputDir string, options RipOptions, artworkPath string, progressChan chan<- RipProgress) error {
	safeTitle := sanitize(track.Title)
	safeArtist := sanitize(track.Artist)

	tempWav := filepath.Join(r.UserDataPath, fmt.Sprintf("rip_%d_track%d.wav", time.Now().UnixNano(), track.Number))

	artistDir := filepath.Join(outputDir, safeArtist)
	if err := os.MkdirAll(artistDir, 0755); err != nil {
		return err
	}

	// Extension map
	ext := "m4a"
	switch options.Format {
	case "flac":
		ext = "flac"
	case "wav":
		ext = "wav"
	case "mp3":
		ext = "mp3"
	}

	filename := fmt.Sprintf("%02d - %s.%s", track.Number, safeTitle, ext)
	finalPath := filepath.Join(artistDir, filename)

	// 1. Rip to WAV
	cdparanoiaPath, err := resolveBinaryPath("cdparanoia", r.CDParanoiaPath)
	if err != nil {
		return fmt.Errorf("cdparanoia not found: %w", err)
	}
	fmt.Printf("[Ripper] Running cdparanoia for track %d\n", track.Number)
	ripCmd := exec.Command(cdparanoiaPath, "-w", strconv.Itoa(track.Number), tempWav)

	// ファイルサイズを監視してリッピング進捗を推定する
	// CD音声セクタ: 2352 bytes/sector、WAVヘッダ: 44 bytes
	expectedBytes := int64(track.Sectors)*2352 + 44
	ripDone := make(chan struct{})
	if progressChan != nil && expectedBytes > 44 {
		go func() {
			ticker := time.NewTicker(400 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ripDone:
					return
				case <-ticker.C:
					info, err := os.Stat(tempWav)
					if err != nil {
						continue
					}
					pct := float64(info.Size()) / float64(expectedBytes) * 95 // 95%上限（エンコード分を残す）
					if pct > 95 {
						pct = 95
					}
					progressChan <- RipProgress{TrackNumber: track.Number, Status: "ripping", Percent: pct}
				}
			}
		}()
	}

	ripOutput, ripErr := ripCmd.CombinedOutput()
	close(ripDone)

	if ripErr != nil {
		os.Remove(tempWav)
		return fmt.Errorf("cdparanoia failed: %w. Output: %s", ripErr, string(ripOutput))
	}
	defer os.Remove(tempWav)

	if progressChan != nil {
		progressChan <- RipProgress{TrackNumber: track.Number, Status: "encoding", Percent: 95}
	}

	// 2. Encode
	fmt.Printf("[Ripper] Encoding track %d to %s\n", track.Number, finalPath)
	var args []string
	args = append(args, "-i", tempWav)

	// Codec configuration
	switch options.Format {
	case "flac":
		args = append(args, "-c:a", "flac")
	case "alac":
		args = append(args, "-c:a", "alac")
	case "wav":
		args = append(args, "-c:a", "pcm_s16le")
	case "mp3":
		args = append(args, "-c:a", "libmp3lame", "-b:a", options.Bitrate)
	case "aac":
		args = append(args, "-c:a", "aac", "-b:a", options.Bitrate)
	default:
		args = append(args, "-c:a", "aac", "-b:a", "320k") // default
	}

	// Metadata
	args = append(args,
		"-metadata", "title="+track.Title,
		"-metadata", "artist="+track.Artist,
		"-metadata", "album="+track.Album,
		"-metadata", fmt.Sprintf("track=%d", track.Number),
	)

	// Artwork
	if artworkPath != "" && options.Format != "wav" {
		args = append(args, "-i", artworkPath, "-map", "0:0", "-map", "1:0", "-c:v", "copy", "-disposition:v", "attached_pic")
	}

	args = append(args, "-y", finalPath)

	ffmpegPath, err := resolveBinaryPath("ffmpeg", r.FFmpegPath)
	if err != nil {
		return fmt.Errorf("ffmpeg not found: %w", err)
	}
	encCmd := exec.Command(ffmpegPath, args...)
	if output, err := encCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg failed: %s: %w", string(output), err)
	}

	return nil
}

func downloadFile(url, dest string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, resp.Body)
	return err
}

func sanitize(name string) string {
	// Simple sanitization
	invalid := []string{"/", "\\", ":", "*", "?", "\"", "<", ">", "|"}
	result := name
	for _, char := range invalid {
		result = strings.ReplaceAll(result, char, "_")
	}
	return result
}
