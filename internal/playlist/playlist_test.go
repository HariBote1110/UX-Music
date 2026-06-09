package playlist

import (
	"os"
	"path/filepath"
	"testing"
	"ux-music-sidecar/internal/config"
)

func TestPlaylistNameTraversalIsRejected(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)

	if err := CreatePlaylist("../escape"); err == nil {
		t.Fatal("CreatePlaylist accepted traversal name")
	}
	if _, err := os.Stat(filepath.Join(tmpDir, "escape.m3u8")); !os.IsNotExist(err) {
		t.Fatalf("playlist escaped Playlists directory: %v", err)
	}

	if err := RenamePlaylist("safe", "../escape"); err == nil {
		t.Fatal("RenamePlaylist accepted traversal destination")
	}
	if err := DeletePlaylist("../escape"); err == nil {
		t.Fatal("DeletePlaylist accepted traversal name")
	}
}

func TestPlaylistNamePathSeparatorIsRejected(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)

	for _, name := range []string{"folder/name", `folder\name`, "  "} {
		if err := CreatePlaylist(name); err == nil {
			t.Fatalf("CreatePlaylist accepted invalid name %q", name)
		}
	}
}
