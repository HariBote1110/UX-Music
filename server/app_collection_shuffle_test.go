package server

import (
	"fmt"
	"sync"
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

func TestSetCollectionShufflePreferenceConcurrentUpdatesKeepAllEntries(t *testing.T) {
	newTempUserDataStore(t)
	app := &App{}
	const workers = 40
	var wg sync.WaitGroup
	errs := make(chan error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs <- app.SetCollectionShufflePreference("album", fmt.Sprintf("Album %03d", i), "on")
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("set preference: %v", err)
		}
	}
	got, err := app.GetCollectionShufflePreferences()
	if err != nil {
		t.Fatalf("get preferences: %v", err)
	}
	if len(got) != workers {
		t.Fatalf("expected %d preferences after concurrent sets, got %d", workers, len(got))
	}
	for i := 0; i < workers; i++ {
		key := collectionShufflePreferenceKey("album", fmt.Sprintf("Album %03d", i))
		if got[key] != "on" {
			t.Fatalf("lost preference %q: %#v", key, got)
		}
	}
}
