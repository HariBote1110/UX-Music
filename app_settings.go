package main

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
	settings, err := store.Instance.Load("settings")
	if err != nil {
		return nil, err
	}
	if settings == nil {
		return make(map[string]interface{}), nil
	}
	return settings, nil
}

// SaveSettings saves the application settings
func (a *App) SaveSettings(settings interface{}) error {
	return store.Instance.Save("settings", settings)
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

	userDataPath := config.GetUserDataPath()
	artworksDir := filepath.Join(userDataPath, "Artworks")
	fullPath := filepath.Join(artworksDir, filename)

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
