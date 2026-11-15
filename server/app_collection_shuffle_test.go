package server

import (
	"fmt"
	"sync"
	"testing"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
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

func TestPlaylistShufflePreferenceRenameSemantics(t *testing.T) {
	setPrefs := func(t *testing.T, entries map[string]interface{}) {
		t.Helper()
		if err := store.Instance.UpdateMap(collectionShuffleStoreName, func(m map[string]interface{}) (bool, error) {
			for k, v := range entries {
				m[k] = v
			}
			return true, nil
		}); err != nil {
			t.Fatalf("seed preferences: %v", err)
		}
	}
	rename := func(t *testing.T, app *App, from, to string) {
		t.Helper()
		if err := playlist.CreatePlaylist(from); err != nil {
			t.Fatalf("create playlist %q: %v", from, err)
		}
		if err := app.RenamePlaylist(map[string]interface{}{"oldName": from, "newName": to}); err != nil {
			t.Fatalf("rename %q -> %q: %v", from, to, err)
		}
	}

	t.Run("overwrites stale entry under new name with old value", func(t *testing.T) {
		newTempUserDataStore(t)
		app := &App{}
		setPrefs(t, map[string]interface{}{
			collectionShufflePreferenceKey("playlist", "Old"):   "on",
			collectionShufflePreferenceKey("playlist", "Fresh"): "off",
		})
		if err := playlist.CreatePlaylist("Old"); err != nil {
			t.Fatalf("create playlist: %v", err)
		}
		if err := app.RenamePlaylist(map[string]interface{}{"oldName": "Old", "newName": "Fresh"}); err != nil {
			t.Fatalf("rename: %v", err)
		}
		got, err := app.GetCollectionShufflePreferences()
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if got["playlist:Fresh"] != "on" {
			t.Fatalf("renamed playlist should own its setting, got %#v", got)
		}
		if _, ok := got["playlist:Old"]; ok {
			t.Fatalf("old key remained: %#v", got)
		}
	})

	t.Run("absent old value removes stale entry under new name", func(t *testing.T) {
		newTempUserDataStore(t)
		app := &App{}
		setPrefs(t, map[string]interface{}{
			collectionShufflePreferenceKey("playlist", "Stale"): "on",
		})
		rename(t, app, "Plain", "Stale")
		got, err := app.GetCollectionShufflePreferences()
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if _, ok := got["playlist:Stale"]; ok {
			t.Fatalf("stale entry survived rename without old value: %#v", got)
		}
	})

	t.Run("invalid old value is dropped and stale new entry removed", func(t *testing.T) {
		newTempUserDataStore(t)
		app := &App{}
		setPrefs(t, map[string]interface{}{
			collectionShufflePreferenceKey("playlist", "Bad"):    "sometimes",
			collectionShufflePreferenceKey("playlist", "Target"): "off",
		})
		rename(t, app, "Bad", "Target")
		raw, err := store.Instance.LoadMap(collectionShuffleStoreName)
		if err != nil {
			t.Fatalf("load raw: %v", err)
		}
		if len(raw) != 0 {
			t.Fatalf("expected no preference entries, got %#v", raw)
		}
	})

	t.Run("trims new name the same way the playlist file is named", func(t *testing.T) {
		newTempUserDataStore(t)
		app := &App{}
		setPrefs(t, map[string]interface{}{
			collectionShufflePreferenceKey("playlist", "Trim"): "on",
		})
		rename(t, app, "Trim", "  Trimmed  ")
		got, err := app.GetCollectionShufflePreferences()
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if got["playlist:Trimmed"] != "on" {
			t.Fatalf("expected key playlist:Trimmed, got %#v", got)
		}
		if _, ok := got["playlist:  Trimmed  "]; ok {
			t.Fatalf("untrimmed key written: %#v", got)
		}
	})

	t.Run("same name after trimming is a no-op", func(t *testing.T) {
		newTempUserDataStore(t)
		app := &App{}
		setPrefs(t, map[string]interface{}{
			collectionShufflePreferenceKey("playlist", "Same"): "off",
		})
		if err := app.renamePlaylistShufflePreference("Same", "  Same "); err != nil {
			t.Fatalf("rename preference: %v", err)
		}
		got, err := app.GetCollectionShufflePreferences()
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if got["playlist:Same"] != "off" || len(got) != 1 {
			t.Fatalf("no-op rename changed preferences: %#v", got)
		}
	})
}
