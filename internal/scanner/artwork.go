package scanner

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/dhowden/tag"
)

func extractAndSaveArtwork(songPath string, artworksDir string) (interface{}, error) {
	albumArtist := ""
	albumTitle := ""
	var imageData []byte

	f, err := os.Open(songPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	m, err := tag.ReadFrom(f)
	if err == nil {
		albumArtist = m.AlbumArtist()
		if albumArtist == "" {
			albumArtist = m.Artist()
		}
		albumTitle = m.Album()
		if p := m.Picture(); p != nil && len(p.Data) > 0 {
			imageData = p.Data
		}
	}

	if imageData == nil {
		if md, probeErr := readMetadataWithFFprobe(songPath); probeErr == nil {
			if albumArtist == "" {
				albumArtist = md.AlbumArtist
			}
			if albumArtist == "" {
				albumArtist = md.Artist
			}
			if albumTitle == "" {
				albumTitle = md.Album
			}
		}

		imageData, err = extractArtworkWithFFmpeg(songPath)
		if err != nil || len(imageData) == 0 {
			return nil, nil
		}
	}

	if albumArtist == "" {
		albumArtist = "Unknown Artist"
	}
	if albumTitle == "" {
		albumTitle = filepath.Base(songPath)
	}

	uniqueKey := fmt.Sprintf("%s---%s", albumArtist, albumTitle)
	hash := fmt.Sprintf("%x", sha256.Sum256([]byte(uniqueKey)))

	fullFileName := hash + ".webp"
	thumbFileName := hash + "_thumb.webp"
	fullPath := filepath.Join(artworksDir, fullFileName)
	thumbPath := filepath.Join(artworksDir, "thumbnails", thumbFileName)

	if _, err := os.Stat(fullPath); err == nil {
		return map[string]string{
			"full":      fullFileName,
			"thumbnail": thumbFileName,
		}, nil
	}

	os.MkdirAll(filepath.Join(artworksDir, "thumbnails"), 0755)

	if err := convertToWebP(imageData, fullPath, 0); err != nil {
		return nil, fmt.Errorf("failed to convert full artwork: %v", err)
	}

	if err := convertToWebP(imageData, thumbPath, 200); err != nil {
		fmt.Printf("[Artwork] Warning: failed to create thumbnail: %v\n", err)
	}

	return map[string]string{
		"full":      fullFileName,
		"thumbnail": thumbFileName,
	}, nil
}

func convertToWebP(data []byte, outputPath string, width int) error {
	ffmpegPath, err := resolveMediaCommandPath("ffmpeg")
	if err != nil {
		return err
	}

	args := []string{"-i", "pipe:0"}
	if width > 0 {
		args = append(args, "-vf", fmt.Sprintf("scale=%d:-1", width))
	}
	args = append(args, "-c:v", "webp", "-q:v", "80", "-y", outputPath)

	cmd := exec.Command(ffmpegPath, args...)
	cmd.Stdin = bytes.NewReader(data)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg error: %v, stderr: %s", err, strings.TrimSpace(stderr.String()))
	}

	return nil
}
