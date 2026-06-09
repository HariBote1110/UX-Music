package server

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

// GetSettings loads settings from settings.json
func (a *App) GetSettings() (interface{}, error) {
	return store.Instance.LoadMap("settings")
}

// SaveSettings saves the application settings
func (a *App) SaveSettings(settings interface{}) error {
	incoming, ok := settings.(map[string]interface{})
	if !ok {
		// Fallback for non-object payloads
		return store.Instance.Save("settings", settings)
	}

	current, err := store.Instance.LoadMap("settings")
	if err != nil {
		return err
	}

	merged := mergeSettings(current, incoming)
	return store.Instance.Save("settings", merged)
}

func mergeSettings(base, patch map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(base)+len(patch))
	for k, v := range base {
		out[k] = v
	}

	for k, v := range patch {
		out[k] = v
	}

	return out
}

// GetArtworksDir returns the path to the artworks directory
func (a *App) GetArtworksDir() string {
	userDataPath := config.GetUserDataPath()
	return filepath.Join(userDataPath, "Artworks")
}

// GetArtworkAsDataURL reads an artwork file and returns it as a base64 data URL
func (a *App) GetArtworkAsDataURL(filename string) (string, error) {
	if filename == "" {
		return "", nil
	}

	fullPath := resolveNowPlayingArtworkPath(filename)
	if fullPath == "" {
		return "", nil
	}

	data, err := os.ReadFile(fullPath)
	if err != nil {
		return "", nil // Ignore errors, return empty
	}

	mimeType := "image/jpeg"
	lowerName := strings.ToLower(filename)
	if strings.HasSuffix(lowerName, ".png") {
		mimeType = "image/png"
	} else if strings.HasSuffix(lowerName, ".webp") {
		mimeType = "image/webp"
	}

	base64Data := base64.StdEncoding.EncodeToString(data)
	return fmt.Sprintf("data:%s;base64,%s", mimeType, base64Data), nil
}
