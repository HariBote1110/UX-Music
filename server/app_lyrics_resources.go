package server

import (
	"os"
	"path/filepath"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

func lyricsSyncModelCacheDir() string {
	return filepath.Join(config.GetUserDataPath(), "lyrics-sync-models")
}

func dirSizeBytes(root string) int64 {
	var total int64
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

// GetLyricsSyncResourceStatus returns cache location, approximate size on disk, and whether the user allowed model downloads.
func (a *App) GetLyricsSyncResourceStatus() map[string]interface{} {
	dir := lyricsSyncModelCacheDir()
	bytes := int64(0)
	if st, err := os.Stat(dir); err == nil && st.IsDir() {
		bytes = dirSizeBytes(dir)
	}

	consent := false
	if m, err := store.Instance.LoadMap("settings"); err == nil {
		if v, ok := m["lyricsSyncModelConsent"].(bool); ok {
			consent = v
		}
	}

	return map[string]interface{}{
		"cachePath":         dir,
		"cacheBytes":        bytes,
		"modelConsent":      consent,
		"appDataEquivalent": config.GetUserDataPath(),
	}
}

// SetLyricsSyncModelConsent persists whether the user allows automatic model downloads for lyrics sync.
func (a *App) SetLyricsSyncModelConsent(approved bool) error {
	base, err := store.Instance.LoadMap("settings")
	if err != nil {
		return err
	}
	base["lyricsSyncModelConsent"] = approved
	return store.Instance.Save("settings", base)
}

// ClearLyricsSyncModelCache removes downloaded ML artefacts (best-effort).
func (a *App) ClearLyricsSyncModelCache() error {
	dir := lyricsSyncModelCacheDir()
	return os.RemoveAll(dir)
}
