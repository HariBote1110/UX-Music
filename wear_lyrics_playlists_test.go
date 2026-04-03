package main

import "testing"

func TestWearPlaylistPathToSongID(t *testing.T) {
	m := map[string]string{
		"/Music/a.flac":                "song-a",
		"/Volumes/lib/album/track.m4a": "song-b",
	}
	if id, ok := wearPlaylistPathToSongID(m, "/Music/a.flac"); !ok || id != "song-a" {
		t.Fatalf("exact: got %q %v", id, ok)
	}
	// Clean collapses .. so playlist lines remain resolvable.
	if id, ok := wearPlaylistPathToSongID(m, "/Volumes/lib/../lib/album/track.m4a"); !ok || id != "song-b" {
		t.Fatalf("clean: got %q %v", id, ok)
	}
	if _, ok := wearPlaylistPathToSongID(m, "/nope.flac"); ok {
		t.Fatal("expected miss")
	}
}
