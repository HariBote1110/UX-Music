package server

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// SelectAndChangeAlbumArtwork opens a file picker, then replaces the artwork
// for every song whose album field matches albumKey.
func (a *App) SelectAndChangeAlbumArtwork(albumKey string) error {
	imagePath, err := wailsRuntime.OpenFileDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "アートワーク画像を選択",
		Filters: []wailsRuntime.FileFilter{
			{
				DisplayName: "画像ファイル (*.jpg;*.jpeg;*.png;*.webp)",
				Pattern:     "*.jpg;*.jpeg;*.png;*.webp",
			},
		},
	})
	if err != nil {
		return fmt.Errorf("dialog error: %w", err)
	}
	if imagePath == "" {
		return nil // cancelled
	}

	imageData, err := os.ReadFile(imagePath)
	if err != nil {
		return fmt.Errorf("cannot read image: %w", err)
	}

	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	thumbsDir := filepath.Join(artworksDir, "thumbnails")
	if err := os.MkdirAll(thumbsDir, 0755); err != nil {
		return fmt.Errorf("cannot create artworks dir: %w", err)
	}

	// Unique filename based on timestamp so it never collides with scanner-generated files
	uid := fmt.Sprintf("custom_%d", time.Now().UnixNano())
	fullFileName := uid + ".webp"
	thumbFileName := uid + "_thumb.webp"
	fullPath := filepath.Join(artworksDir, fullFileName)
	thumbPath := filepath.Join(thumbsDir, thumbFileName)

	if err := convertImageToWebP(imageData, fullPath, 0); err != nil {
		return fmt.Errorf("artwork conversion failed: %w", err)
	}
	if err := convertImageToWebP(imageData, thumbPath, 200); err != nil {
		fmt.Printf("[Artwork] Warning: thumbnail creation failed: %v\n", err)
	}

	newArtwork := map[string]string{
		"full":      fullFileName,
		"thumbnail": thumbFileName,
	}

	// Update every matching song in the persisted library
	arr, err := store.Instance.LoadSlice("library")
	if err != nil {
		return fmt.Errorf("library format invalid")
	}

	normKey := strings.ToLower(strings.TrimSpace(albumKey))
	updated := false
	for _, item := range arr {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		album, _ := m["album"].(string)
		if strings.ToLower(strings.TrimSpace(album)) == normKey {
			m["artwork"] = newArtwork
			updated = true
		}
	}

	if !updated {
		return fmt.Errorf("no songs found for album: %s", albumKey)
	}

	if err := store.Instance.Save("library", arr); err != nil {
		return fmt.Errorf("failed to save library: %w", err)
	}

	wailsRuntime.EventsEmit(a.ctx, "artwork-changed", map[string]interface{}{
		"albumKey": albumKey,
		"artwork":  newArtwork,
	})

	return nil
}

func convertImageToWebP(data []byte, outputPath string, width int) error {
	ffmpegPath, err := locateFfmpeg()
	if err != nil {
		return fmt.Errorf("ffmpeg not found: %w", err)
	}

	args := []string{"-i", "pipe:0"}
	if width > 0 {
		args = append(args, "-vf", fmt.Sprintf("scale=%d:-1", width))
	}
	args = append(args, "-c:v", "webp", "-q:v", "85", "-y", outputPath)

	cmd := exec.Command(ffmpegPath, args...)
	cmd.Stdin = bytes.NewReader(data)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg: %v — %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
