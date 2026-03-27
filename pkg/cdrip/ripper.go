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
	"strconv"
	"strings"
	"time"
)

// Ripper manages CD ripping operations
type Ripper struct {
	CDParanoiaPath string
	FFmpegPath     string
	UserDataPath   string
}

// NewRipper creates a new Ripper instance
func NewRipper(cdParanoiaPath, ffmpegPath, userDataPath string) *Ripper {
	return &Ripper{
		CDParanoiaPath: cdParanoiaPath,
		FFmpegPath:     ffmpegPath,
		UserDataPath:   userDataPath,
	}
}

// GetTrackList scans the CD for tracks
func (r *Ripper) GetTrackList() ([]Track, error) {
	cmd := exec.Command(r.CDParanoiaPath, "-Q")
	var out bytes.Buffer
	// cdparanoia outputs to stderr usually
	cmd.Stderr = &out
	cmd.Stdout = &out // Capture both just in case

	if err := cmd.Run(); err != nil {
		// It might return non-zero if no CD is found
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

		err := r.ripAndConvert(track, outputDir, options, artworkPath)

		if err != nil {
			fmt.Printf("[Ripper] Error processing track %d: %v\n", track.Number, err)
			if progressChan != nil {
				progressChan <- RipProgress{TrackNumber: track.Number, Status: "error", Error: err.Error()}
			}
			return err // Or continue? Abort for now.
		}

		fmt.Printf("[Ripper] Completed track %d\n", track.Number)
		if progressChan != nil {
			progressChan <- RipProgress{TrackNumber: track.Number, Status: "completed"}
		}
	}

	return nil
}

func (r *Ripper) ripAndConvert(track Track, outputDir string, options RipOptions, artworkPath string) error {
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
	fmt.Printf("[Ripper] Running cdparanoia for track %d\n", track.Number)
	ripCmd := exec.Command(r.CDParanoiaPath, "-w", strconv.Itoa(track.Number), tempWav)
	if output, err := ripCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("cdparanoia failed: %w. Output: %s", err, string(output))
	}
	defer os.Remove(tempWav)

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

	encCmd := exec.Command(r.FFmpegPath, args...)
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
