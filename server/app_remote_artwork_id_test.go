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
	// The charset was widened beyond 64-hex so sync-imported "dev_"/"custom_"
	// stems resolve to their real on-disk file instead of falling back to a
	// recomputed album hash that names nothing (see isServableArtworkStem).
	// A "_thumb"-suffixed or non-hex stem is still within the safe charset
	// (letters, digits, '.', '_', '-') and is therefore accepted as-is.
	t.Run("accepts thumbnail-suffix-shaped stem (safe charset, not path-shaped)", func(t *testing.T) {
		got := hashStemFromArtworkFilename(hash + "_thumb.webp")
		want := hash + "_thumb"
		if got != want {
			t.Fatalf("got %q want %q", got, want)
		}
	})
	t.Run("accepts non-hex letters within safe charset", func(t *testing.T) {
		const stem = "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"
		got := hashStemFromArtworkFilename(stem + ".webp")
		if got != stem {
			t.Fatalf("got %q want %q", got, stem)
		}
	})
	t.Run("reject stem starting with dot", func(t *testing.T) {
		got := hashStemFromArtworkFilename(".hidden.webp")
		if got != "" {
			t.Fatalf("expected empty, got %q", got)
		}
	})
}

func TestIsServableArtworkStem(t *testing.T) {
	cases := map[string]bool{
		"dev_4f8215d65ae49bdc12d1576716a4cc97-3030b09b": true,
		"custom_abc.123":   true,
		"abcdef0123456789": true,
		"":                 false,
		".hidden":          false,
		"../evil":          false,
		"a/b":              false,
		`a\b`:              false,
	}
	for id, want := range cases {
		if got := isServableArtworkStem(id); got != want {
			t.Fatalf("isServableArtworkStem(%q) = %v want %v", id, got, want)
		}
	}
}

func TestArtworkIDForRemoteSong_prefersArtworkFull(t *testing.T) {
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
	got := artworkIDForRemoteSong(song)
	if got != onDisk {
		t.Fatalf("got %q want %q (must match disk file stem, not recomputed from tags)", got, onDisk)
	}
}

func TestArtworkIDForRemoteSong_fallbackUsesArtistWhenAlbumArtistEmpty(t *testing.T) {
	song := map[string]interface{}{
		"albumartist": "",
		"artist":      "Band",
		"album":       "LP",
		"path":        "/x/y/track.m4a",
	}
	got := artworkIDForRemoteSong(song)
	want := computeArtworkID("Band", "LP")
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

// TestArtworkIDForRemoteSong_devStemFromSyncImport reproduces the artwork
// 404 seen for sync-imported songs: their stored artwork.full is named
// "dev_<hash>-<uuid>.webp" (see internal/uxsync import path), not a 64-hex
// scanner stem, so the ID exposed to remote clients must be the real
// on-disk stem rather than a recomputed album hash that names no file.
func TestArtworkIDForRemoteSong_devStemFromSyncImport(t *testing.T) {
	const stem = "dev_4f8215d65ae49bdc12d1576716a4cc97-3030b09b-1234-4abc-9def-abcdef123456"
	song := map[string]interface{}{
		"albumartist": "Some Artist",
		"album":       "Some Album",
		"path":        "/music/synced.flac",
		"artwork": map[string]interface{}{
			"full": stem + ".webp",
		},
	}
	got := artworkIDForRemoteSong(song)
	if got != stem {
		t.Fatalf("got %q want %q (must match real on-disk dev_ stem, not album-hash fallback)", got, stem)
	}
}
