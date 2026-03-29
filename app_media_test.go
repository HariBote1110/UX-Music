package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"ux-music-sidecar/internal/config"
)

func TestResolveNowPlayingArtworkPath(t *testing.T) {
	// Setup temporary directory for tests
	tmpDir, err := os.MkdirTemp("", "ux-music-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	config.SetUserDataPath(tmpDir)

	artworksDir := filepath.Join(tmpDir, "Artworks")
	err = os.Mkdir(artworksDir, 0755)
	if err != nil {
		t.Fatalf("Failed to create Artworks dir: %v", err)
	}

	validRelativeImage := "test-image.jpg"
	validRelativeImagePath := filepath.Join(artworksDir, validRelativeImage)
	err = os.WriteFile(validRelativeImagePath, []byte("dummy data"), 0644)
	if err != nil {
		t.Fatalf("Failed to create dummy image: %v", err)
	}
	cleanValidRelativeImagePath := filepath.Clean(validRelativeImagePath)

	validAbsoluteImage := filepath.Join(tmpDir, "absolute-image.jpg")
	err = os.WriteFile(validAbsoluteImage, []byte("dummy data"), 0644)
	if err != nil {
		t.Fatalf("Failed to create dummy absolute image: %v", err)
	}
	cleanValidAbsoluteImage := filepath.Clean(validAbsoluteImage)

	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "empty string",
			raw:  "",
			want: "",
		},
		{
			name: "whitespace string",
			raw:  "   ",
			want: "",
		},
		{
			name: "http url",
			raw:  "http://example.com/image.jpg",
			want: "",
		},
		{
			name: "https url",
			raw:  "https://example.com/image.jpg",
			want: "",
		},
		{
			name: "data uri",
			raw:  "data:image/jpeg;base64,123",
			want: "",
		},
		{
			name: "blob uri",
			raw:  "blob:http://localhost/123",
			want: "",
		},
		{
			name: "safe-artwork with valid relative image",
			raw:  "safe-artwork://" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "safe-artwork with single slash",
			raw:  "safe-artwork/" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "safe-artwork with leading slash",
			raw:  "/safe-artwork/" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "url encoded safe-artwork",
			raw:  "safe-artwork://" + strings.ReplaceAll(validRelativeImage, "-", "%2D"),
			want: cleanValidRelativeImagePath,
		},
		{
			name: "absolute path existing",
			raw:  validAbsoluteImage,
			want: cleanValidAbsoluteImage,
		},
		{
			name: "absolute path non-existing",
			raw:  filepath.Join(tmpDir, "non-existing.jpg"),
			want: "",
		},
		{
			name: "relative traversal out of directory",
			raw:  "safe-artwork://../absolute-image.jpg",
			want: "",
		},
		{
			name: "relative traversal root",
			raw:  "..",
			want: "",
		},
		{
			name: "relative traversal current dir",
			raw:  ".",
			want: "",
		},
		{
			name: "non-existent relative image",
			raw:  "non-existent.jpg",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolveNowPlayingArtworkPath(tt.raw)
			if got != tt.want {
				t.Errorf("resolveNowPlayingArtworkPath(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}
