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
	preferences := map[string]string{}
	err := store.Instance.UpdateMap(collectionShuffleStoreName, func(raw map[string]interface{}) (bool, error) {
		for key, value := range raw {
			preference, ok := value.(string)
			if ok && (strings.HasPrefix(key, "album:") || strings.HasPrefix(key, "playlist:")) && (preference == "on" || preference == "off") {
				preferences[key] = preference
			}
		}
		return false, nil
	})
	if err != nil {
		return nil, err
	}
	return preferences, nil
}

// SetCollectionShufflePreference persists an album or playlist default.
// preference == "" clears the default instead of storing an unset value.
func (a *App) SetCollectionShufflePreference(kind string, key string, preference string) error {
	if err := validateCollectionShufflePreference(kind, key, preference); err != nil {
		return err
	}
	preferenceKey := collectionShufflePreferenceKey(kind, key)
	return store.Instance.UpdateMap(collectionShuffleStoreName, func(raw map[string]interface{}) (bool, error) {
		if preference == "" {
			if _, exists := raw[preferenceKey]; !exists {
				return false, nil
			}
			delete(raw, preferenceKey)
			return true, nil
		}
		raw[preferenceKey] = preference
		return true, nil
	})
}

func (a *App) renamePlaylistShufflePreference(oldName string, newName string) error {
	oldKey := collectionShufflePreferenceKey("playlist", oldName)
	newKey := collectionShufflePreferenceKey("playlist", newName)
	return store.Instance.UpdateMap(collectionShuffleStoreName, func(raw map[string]interface{}) (bool, error) {
		preference, exists := raw[oldKey]
		if !exists {
			return false, nil
		}
		delete(raw, oldKey)
		if value, ok := preference.(string); ok && (value == "on" || value == "off") {
			raw[newKey] = value
		}
		return true, nil
	})
}

func (a *App) deletePlaylistShufflePreference(name string) error {
	key := collectionShufflePreferenceKey("playlist", name)
	return store.Instance.UpdateMap(collectionShuffleStoreName, func(raw map[string]interface{}) (bool, error) {
		if _, exists := raw[key]; !exists {
			return false, nil
		}
		delete(raw, key)
		return true, nil
	})
}
