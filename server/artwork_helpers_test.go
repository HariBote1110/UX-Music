package server

import "testing"

func TestArtworkPathFromSong_MapShapePrefersThumbnail(t *testing.T) {
	song := map[string]interface{}{
		"artwork": map[string]interface{}{
			"full":      "full.webp",
			"thumbnail": "full_thumb.webp",
		},
	}
	if got := artworkPathFromSong(song); got != "full_thumb.webp" {
		t.Fatalf("got %q, want thumbnail", got)
	}
}

func TestArtworkPathFromSong_MapStringShape(t *testing.T) {
	// extractAndSaveArtwork returns map[string]string before any JSON round-trip.
	song := map[string]interface{}{
		"artwork": map[string]string{
			"full":      "full.webp",
			"thumbnail": "full_thumb.webp",
		},
	}
	if got := artworkPathFromSong(song); got != "full_thumb.webp" {
		t.Fatalf("got %q, want thumbnail", got)
	}
}

func TestArtworkPathFromSong_MapShapeFallsBackToFullWhenNoThumbnail(t *testing.T) {
	song := map[string]interface{}{
		"artwork": map[string]interface{}{
			"full": "full.webp",
		},
	}
	if got := artworkPathFromSong(song); got != "full.webp" {
		t.Fatalf("got %q, want full", got)
	}
}

func TestArtworkPathFromSong_StringShapeForYouTube(t *testing.T) {
	song := map[string]interface{}{
		"artwork": "https://example.com/thumb.jpg",
	}
	if got := artworkPathFromSong(song); got != "https://example.com/thumb.jpg" {
		t.Fatalf("got %q, want raw string", got)
	}
}

func TestArtworkPathFromSong_MissingReturnsEmpty(t *testing.T) {
	song := map[string]interface{}{"title": "x"}
	if got := artworkPathFromSong(song); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestArtworkPathFromSong_EmptyStringReturnsEmpty(t *testing.T) {
	song := map[string]interface{}{"artwork": ""}
	if got := artworkPathFromSong(song); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestArtworkPathFromSong_NilSongReturnsEmpty(t *testing.T) {
	if got := artworkPathFromSong(nil); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func songWithArtwork(album, artwork string) map[string]interface{} {
	return map[string]interface{}{"album": album, "artwork": artwork}
}

func TestCollageArtworks_FourPlusSongsYieldFourDistinctByAlbum(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Album A", "a.webp"),
		songWithArtwork("Album B", "b.webp"),
		songWithArtwork("Album C", "c.webp"),
		songWithArtwork("Album D", "d.webp"),
		songWithArtwork("Album E", "e.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 4 {
		t.Fatalf("len = %d, want 4; got %v", len(got), got)
	}
}

func TestCollageArtworks_SingleAlbumPlaylistReturnsOnlyOneUniqueCover(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Same Album", "same.webp"),
		songWithArtwork("Same Album", "same.webp"),
		songWithArtwork("Same Album", "same.webp"),
		songWithArtwork("Same Album", "same.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1 (no padding with repeats); got %v", len(got), got)
	}
}

func TestCollageArtworks_FewerThanFourUniqueReturnsOnlyUnique(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Album A", "a.webp"),
		songWithArtwork("Album B", "b.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2; got %v", len(got), got)
	}
}

func TestCollageArtworks_SkipsSongsWithoutArtwork(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"album": "Album A"},
		songWithArtwork("Album B", "b.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 1 || got[0] != "b.webp" {
		t.Fatalf("got %v, want [b.webp]", got)
	}
}
