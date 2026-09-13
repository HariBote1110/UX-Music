package server

import (
	"fmt"
	"strings"
	"ux-music-sidecar/internal/store"
)

const collectionShuffleStoreName = "collection-shuffle"

func collectionShufflePreferenceKey(kind string, key string) string {
	return kind + ":" + key
}

func validateCollectionShufflePreference(kind string, key string, preference string) error {
	if kind != "album" && kind != "playlist" {
		return fmt.Errorf("invalid collection kind %q", kind)
	}
	if strings.TrimSpace(key) == "" {
		return fmt.Errorf("collection key must not be empty")
	}
	if preference != "on" && preference != "off" && preference != "" {
		return fmt.Errorf("invalid shuffle preference %q", preference)
	}
	return nil
}

// GetCollectionShufflePreferences returns persisted collection defaults. Keys
// are "album:<albumKey>" or "playlist:<playlistName>" and values are "on"
// or "off"; absent keys intentionally represent an unset preference.
func (a *App) GetCollectionShufflePreferences() (map[string]string, error) {
	raw, err := store.Instance.LoadMap(collectionShuffleStoreName)
	if err != nil {
		return nil, err
	}
	preferences := make(map[string]string, len(raw))
	for key, value := range raw {
		preference, ok := value.(string)
		if ok && (strings.HasPrefix(key, "album:") || strings.HasPrefix(key, "playlist:")) && (preference == "on" || preference == "off") {
			preferences[key] = preference
		}
	}
	return preferences, nil
}

// SetCollectionShufflePreference persists an album or playlist default.
// preference == "" clears the default instead of storing an unset value.
func (a *App) SetCollectionShufflePreference(kind string, key string, preference string) error {
	if err := validateCollectionShufflePreference(kind, key, preference); err != nil {
		return err
	}
	raw, err := store.Instance.LoadMap(collectionShuffleStoreName)
	if err != nil {
		return err
	}
	preferenceKey := collectionShufflePreferenceKey(kind, key)
	if preference == "" {
		delete(raw, preferenceKey)
	} else {
		raw[preferenceKey] = preference
	}
	return store.Instance.Save(collectionShuffleStoreName, raw)
}

func (a *App) renamePlaylistShufflePreference(oldName string, newName string) error {
	raw, err := store.Instance.LoadMap(collectionShuffleStoreName)
	if err != nil {
		return err
	}
	oldKey := collectionShufflePreferenceKey("playlist", oldName)
	preference, exists := raw[oldKey]
	if !exists {
		return nil
	}
	delete(raw, oldKey)
	if value, ok := preference.(string); ok && (value == "on" || value == "off") {
		raw[collectionShufflePreferenceKey("playlist", newName)] = value
	}
	return store.Instance.Save(collectionShuffleStoreName, raw)
}

func (a *App) deletePlaylistShufflePreference(name string) error {
	raw, err := store.Instance.LoadMap(collectionShuffleStoreName)
	if err != nil {
		return err
	}
	key := collectionShufflePreferenceKey("playlist", name)
	if _, exists := raw[key]; !exists {
		return nil
	}
	delete(raw, key)
	return store.Instance.Save(collectionShuffleStoreName, raw)
}
