package server

import (
	"testing"
)

func TestHashStemFromArtworkFilename(t *testing.T) {
	const hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	t.Run("webp basename", func(t *testing.T) {
		got := hashStemFromArtworkFilename(hash + ".webp")
		if got != hash {
			t.Fatalf("got %q want %q", got, hash)
		}
	})
	t.Run("path with subdir", func(t *testing.T) {
		got := hashStemFromArtworkFilename("thumbnails/" + hash + ".png")
		if got != hash {
			t.Fatalf("got %q want %q", got, hash)
		}
	})
	t.Run("reject thumbnail suffix file", func(t *testing.T) {
		got := hashStemFromArtworkFilename(hash + "_thumb.webp")
		if got != "" {
			t.Fatalf("expected empty, got %q", got)
		}
	})
	t.Run("reject non hex", func(t *testing.T) {
		got := hashStemFromArtworkFilename("GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG.webp")
		if got != "" {
			t.Fatalf("expected empty, got %q", got)
		}
	})
}

func TestArtworkIDForWearSong_prefersArtworkFull(t *testing.T) {
	const onDisk = "1111111111111111111111111111111111111111111111111111111111111111"
	song := map[string]interface{}{
		"albumartist": "",
		"artist":      "Display Artist",
		"album":       "Some Album",
		"path":        "/music/a.flac",
		"artwork": map[string]interface{}{
			"full":      onDisk + ".webp",
			"thumbnail": onDisk + "_thumb.webp",
		},
	}
	got := artworkIDForWearSong(song)
	if got != onDisk {
		t.Fatalf("got %q want %q (must match disk file stem, not recomputed from tags)", got, onDisk)
	}
}

func TestArtworkIDForWearSong_fallbackUsesArtistWhenAlbumArtistEmpty(t *testing.T) {
	song := map[string]interface{}{
		"albumartist": "",
		"artist":      "Band",
		"album":       "LP",
		"path":        "/x/y/track.m4a",
	}
	got := artworkIDForWearSong(song)
	want := computeArtworkID("Band", "LP")
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
