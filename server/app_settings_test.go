package server

import (
	"os"
	"path/filepath"
	"testing"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

func TestGetArtworkAsDataURLRejectsTraversal(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

	if err := os.MkdirAll(filepath.Join(tmpDir, "Artworks"), 0755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(tmpDir, "outside.jpg")
	if err := os.WriteFile(outside, []byte("not artwork"), 0644); err != nil {
		t.Fatal(err)
	}

	got, err := (&App{}).GetArtworkAsDataURL("../outside.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Fatalf("GetArtworkAsDataURL returned data for traversal path: %q", got)
	}
}
