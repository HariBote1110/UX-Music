package server

import (
	"testing"
	"ux-music-sidecar/internal/playlist"
)

func TestCollectionShufflePreferencesPersistAndValidate(t *testing.T) {
	newTempUserDataStore(t)
	app := &App{}

	if err := app.SetCollectionShufflePreference("album", "Artist — Album", "on"); err != nil {
		t.Fatalf("set album preference: %v", err)
	}
	if err := app.SetCollectionShufflePreference("playlist", "Morning", "off"); err != nil {
		t.Fatalf("set playlist preference: %v", err)
	}
	got, err := app.GetCollectionShufflePreferences()
	if err != nil {
		t.Fatalf("get preferences: %v", err)
	}
	if got["album:Artist — Album"] != "on" || got["playlist:Morning"] != "off" {
		t.Fatalf("preferences = %#v", got)
	}
	if err := app.SetCollectionShufflePreference("album", "", "on"); err == nil {
		t.Fatal("empty key was accepted")
	}
	if err := app.SetCollectionShufflePreference("artist", "Name", "on"); err == nil {
		t.Fatal("invalid kind was accepted")
	}
	if err := app.SetCollectionShufflePreference("album", "Name", "sometimes"); err == nil {
		t.Fatal("invalid preference was accepted")
	}
	if err := app.SetCollectionShufflePreference("album", "Artist — Album", ""); err != nil {
		t.Fatalf("clear preference: %v", err)
	}
	got, err = app.GetCollectionShufflePreferences()
	if err != nil {
		t.Fatalf("get after clear: %v", err)
	}
	if _, ok := got["album:Artist — Album"]; ok {
		t.Fatalf("cleared preference remained: %#v", got)
	}
}

func TestPlaylistShufflePreferenceMovesOnRenameAndIsRemovedOnDelete(t *testing.T) {
	newTempUserDataStore(t)
	app := &App{}
	if err := playlist.CreatePlaylist("Before"); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if err := app.SetCollectionShufflePreference("playlist", "Before", "on"); err != nil {
		t.Fatalf("set preference: %v", err)
	}
	if err := app.RenamePlaylist(map[string]interface{}{"oldName": "Before", "newName": "After"}); err != nil {
		t.Fatalf("rename playlist: %v", err)
	}
	got, err := app.GetCollectionShufflePreferences()
	if err != nil {
		t.Fatalf("get after rename: %v", err)
	}
	if got["playlist:After"] != "on" {
		t.Fatalf("renamed preference = %#v", got)
	}
	if _, ok := got["playlist:Before"]; ok {
		t.Fatalf("old preference remained: %#v", got)
	}
	if err := app.DeletePlaylist("After"); err != nil {
		t.Fatalf("delete playlist: %v", err)
	}
	got, err = app.GetCollectionShufflePreferences()
	if err != nil {
		t.Fatalf("get after delete: %v", err)
	}
	if _, ok := got["playlist:After"]; ok {
		t.Fatalf("deleted preference remained: %#v", got)
	}
}
