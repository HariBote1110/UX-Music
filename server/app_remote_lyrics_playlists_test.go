package server

import "testing"

func TestRemotePlaylistPathToSongID(t *testing.T) {
	m := map[string]string{
		"/Music/a.flac":                "song-a",
		"/Volumes/lib/album/track.m4a": "song-b",
	}
	if id, ok := remotePlaylistPathToSongID(m, "/Music/a.flac"); !ok || id != "song-a" {
		t.Fatalf("exact: got %q %v", id, ok)
	}
	// Clean collapses .. so playlist lines remain resolvable.
	if id, ok := remotePlaylistPathToSongID(m, "/Volumes/lib/../lib/album/track.m4a"); !ok || id != "song-b" {
		t.Fatalf("clean: got %q %v", id, ok)
	}
	if _, ok := remotePlaylistPathToSongID(m, "/nope.flac"); ok {
		t.Fatal("expected miss")
	}
}
