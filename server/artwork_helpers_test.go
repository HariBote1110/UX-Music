package server

import "testing"

func TestArtworkPathFromSong_MapShapePreservesFullAndThumbnail(t *testing.T) {
	song := map[string]interface{}{
		"artwork": map[string]interface{}{
			"full":      "full.webp",
			"thumbnail": "full_thumb.webp",
		},
	}
	got, ok := artworkPathFromSong(song).(map[string]interface{})
	if !ok {
		t.Fatalf("got %#v, want map[string]interface{}", artworkPathFromSong(song))
	}
	if got["full"] != "full.webp" || got["thumbnail"] != "full_thumb.webp" {
		t.Fatalf("got %#v, want full/thumbnail preserved", got)
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
	got, ok := artworkPathFromSong(song).(map[string]interface{})
	if !ok {
		t.Fatalf("got %#v, want map[string]interface{}", artworkPathFromSong(song))
	}
	if got["full"] != "full.webp" || got["thumbnail"] != "full_thumb.webp" {
		t.Fatalf("got %#v, want full/thumbnail preserved", got)
	}
}

func TestArtworkPathFromSong_MapShapeWithNoThumbnailStillPreservesFull(t *testing.T) {
	song := map[string]interface{}{
		"artwork": map[string]interface{}{
			"full": "full.webp",
		},
	}
	got, ok := artworkPathFromSong(song).(map[string]interface{})
	if !ok {
		t.Fatalf("got %#v, want map[string]interface{}", artworkPathFromSong(song))
	}
	if got["full"] != "full.webp" {
		t.Fatalf("got %#v, want full preserved", got)
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

func TestArtworkPathFromSong_MissingReturnsNil(t *testing.T) {
	song := map[string]interface{}{"title": "x"}
	if got := artworkPathFromSong(song); got != nil {
		t.Fatalf("got %#v, want nil", got)
	}
}

func TestArtworkPathFromSong_EmptyStringReturnsNil(t *testing.T) {
	song := map[string]interface{}{"artwork": ""}
	if got := artworkPathFromSong(song); got != nil {
		t.Fatalf("got %#v, want nil", got)
	}
}

func TestArtworkPathFromSong_NilSongReturnsNil(t *testing.T) {
	if got := artworkPathFromSong(nil); got != nil {
		t.Fatalf("got %#v, want nil", got)
	}
}

func songWithArtwork(album, full, thumbnail string) map[string]interface{} {
	return map[string]interface{}{
		"album":   album,
		"artwork": map[string]interface{}{"full": full, "thumbnail": thumbnail},
	}
}

func TestCollageArtworks_FourPlusSongsYieldFourDistinctByAlbum(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Album A", "a.webp", "a_thumb.webp"),
		songWithArtwork("Album B", "b.webp", "b_thumb.webp"),
		songWithArtwork("Album C", "c.webp", "c_thumb.webp"),
		songWithArtwork("Album D", "d.webp", "d_thumb.webp"),
		songWithArtwork("Album E", "e.webp", "e_thumb.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 4 {
		t.Fatalf("len = %d, want 4; got %v", len(got), got)
	}
}

func TestCollageArtworks_SingleAlbumPlaylistReturnsOnlyOneUniqueCover(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Same Album", "same.webp", "same_thumb.webp"),
		songWithArtwork("Same Album", "same.webp", "same_thumb.webp"),
		songWithArtwork("Same Album", "same.webp", "same_thumb.webp"),
		songWithArtwork("Same Album", "same.webp", "same_thumb.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1 (no padding with repeats); got %v", len(got), got)
	}
}

func TestCollageArtworks_FewerThanFourUniqueReturnsOnlyUnique(t *testing.T) {
	songs := []interface{}{
		songWithArtwork("Album A", "a.webp", "a_thumb.webp"),
		songWithArtwork("Album B", "b.webp", "b_thumb.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2; got %v", len(got), got)
	}
}

func TestCollageArtworks_SkipsSongsWithoutArtwork(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"album": "Album A"},
		songWithArtwork("Album B", "b.webp", "b_thumb.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 1 {
		t.Fatalf("got %v, want 1 entry", got)
	}
	entry, ok := got[0].(map[string]interface{})
	if !ok || entry["thumbnail"] != "b_thumb.webp" {
		t.Fatalf("got %#v, want thumbnail b_thumb.webp", got[0])
	}
}

func TestCollageArtworks_DedupesByThumbnailNameAcrossAlbums(t *testing.T) {
	// Two songs share the same underlying artwork file even though their
	// album metadata differs (e.g. a compilation). The collage must not
	// show the same cover twice.
	songs := []interface{}{
		songWithArtwork("Album A", "shared.webp", "shared_thumb.webp"),
		songWithArtwork("Album B (Deluxe)", "shared.webp", "shared_thumb.webp"),
	}
	got := collageArtworks(songs)
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1 (deduped by thumbnail); got %v", len(got), got)
	}
}
