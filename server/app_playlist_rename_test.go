package server

import (
	"strings"
	"testing"
	"ux-music-sidecar/internal/playlist"
)

func TestRenamePlaylistRejectsNonStringNamesWithoutSideEffects(t *testing.T) {
	newTempUserDataStore(t)
	app := &App{}
	if err := playlist.CreatePlaylist("Keep"); err != nil {
		t.Fatalf("create playlist: %v", err)
	}

	cases := []map[string]interface{}{
		{"newName": "Other"},
		{"oldName": "Keep"},
		{"oldName": 1, "newName": "Other"},
		{"oldName": "Keep", "newName": nil},
	}
	for _, data := range cases {
		err := callRenamePlaylistNoPanic(t, app, data)
		if err == nil {
			t.Fatalf("RenamePlaylist(%#v) accepted invalid input", data)
		}
		if !strings.Contains(err.Error(), "must be a string") {
			t.Fatalf("RenamePlaylist(%#v) error = %v, want a 'must be a string' error", data, err)
		}
	}

	names, err := playlist.GetAllPlaylists()
	if err != nil {
		t.Fatalf("list playlists: %v", err)
	}
	if len(names) != 1 || names[0] != "Keep" {
		t.Fatalf("invalid rename changed playlists: %#v", names)
	}
}

func callRenamePlaylistNoPanic(t *testing.T, app *App, data map[string]interface{}) (err error) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("RenamePlaylist(%#v) panicked: %v", data, r)
		}
	}()
	return app.RenamePlaylist(data)
}
