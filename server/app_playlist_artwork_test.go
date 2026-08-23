package server

import (
	"context"
	"testing"

	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
)

// TestRequestPlaylistsWithArtwork_MapShapedArtworkPopulatesCollage
// reproduces the playlist collage bug: RequestPlaylistsWithArtwork used to
// type-assert song["artwork"] straight to string, but scanned local songs
// store it as {"full":..., "thumbnail":...} (internal/scanner/artwork.go),
// so every collage silently came back empty.
func TestRequestPlaylistsWithArtwork_MapShapedArtworkPopulatesCollage(t *testing.T) {
	newTempUserDataStore(t)

	library := []map[string]interface{}{
		{"path": "/music/a.flac", "album": "Album A", "artwork": map[string]interface{}{"full": "a.webp", "thumbnail": "a_thumb.webp"}},
		{"path": "/music/b.flac", "album": "Album B", "artwork": map[string]interface{}{"full": "b.webp", "thumbnail": "b_thumb.webp"}},
	}
	if err := store.Instance.Save("library", library); err != nil {
		t.Fatalf("save library: %v", err)
	}

	if err := playlist.CreatePlaylist("My Playlist"); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := playlist.AddSongsToPlaylist("My Playlist", []playlist.SongToAdd{
		{Path: "/music/a.flac", Title: "A"},
		{Path: "/music/b.flac", Title: "B"},
	}); err != nil {
		t.Fatalf("add songs: %v", err)
	}

	a := NewApp()
	a.ctx = context.Background()
	origEventsEmitFunc := eventsEmitFunc
	defer func() { eventsEmitFunc = origEventsEmitFunc }()

	var payload interface{}
	eventsEmitFunc = func(_ context.Context, name string, data interface{}) {
		if name == "playlists-updated" {
			payload = data
		}
	}

	a.RequestPlaylistsWithArtwork()

	playlists, ok := payload.([]interface{})
	if !ok || len(playlists) != 1 {
		t.Fatalf("payload = %#v", payload)
	}
	entry, ok := playlists[0].(map[string]interface{})
	if !ok {
		t.Fatalf("entry = %#v", playlists[0])
	}
	artworks, ok := entry["artworks"].([]interface{})
	if !ok || len(artworks) != 2 {
		t.Fatalf("artworks = %#v, want 2 entries", entry["artworks"])
	}
	first, ok := artworks[0].(map[string]interface{})
	if !ok || first["thumbnail"] != "a_thumb.webp" || first["full"] != "a.webp" {
		t.Fatalf("artworks[0] = %#v, want full/thumbnail object for a", artworks[0])
	}
	second, ok := artworks[1].(map[string]interface{})
	if !ok || second["thumbnail"] != "b_thumb.webp" || second["full"] != "b.webp" {
		t.Fatalf("artworks[1] = %#v, want full/thumbnail object for b", artworks[1])
	}
}
