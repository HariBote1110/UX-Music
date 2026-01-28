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
	"ux-music-sidecar/internal/config"

	"github.com/dhowden/tag"
)

func extractAndSaveArtwork(songPath string, artworksDir string) (interface{}, error) {
	f, err := os.Open(songPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	m, err := tag.ReadFrom(f)
	if err != nil {
		return nil, err
	}

	p := m.Picture()
	if p == nil {
		return nil, nil
	}

	albumArtist := m.AlbumArtist()
	if albumArtist == "" {
		albumArtist = m.Artist()
	}
	albumTitle := m.Album()
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

	if err := convertToWebP(p.Data, fullPath, 0); err != nil {
		return nil, fmt.Errorf("failed to convert full artwork: %v", err)
	}

	if err := convertToWebP(p.Data, thumbPath, 200); err != nil {
		fmt.Printf("[Artwork] Warning: failed to create thumbnail: %v\n", err)
	}

	return map[string]string{
		"full":      fullFileName,
		"thumbnail": thumbFileName,
	}, nil
}

func convertToWebP(data []byte, outputPath string, width int) error {
	if config.FFmpegPath == "" {
		return fmt.Errorf("ffmpeg path not set")
	}

	args := []string{"-i", "pipe:0"}
	if width > 0 {
		args = append(args, "-vf", fmt.Sprintf("scale=%d:-1", width))
	}
	args = append(args, "-c:v", "webp", "-q:v", "80", "-y", outputPath)

	cmd := exec.Command(config.FFmpegPath, args...)
	cmd.Stdin = bytes.NewReader(data)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg error: %v, stderr: %s", err, stderr.String())
	}

	return nil
}
