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

// renamePlaylistShufflePreference moves a playlist's default to its new name.
// Names are trimmed the same way internal/playlist does, so the keys match the
// names the playlist actually ends up with. A pre-existing entry under the new
// name is an orphan from an earlier playlist; the renamed playlist's own
// setting wins, so it is overwritten or removed.
func (a *App) renamePlaylistShufflePreference(oldName string, newName string) error {
	oldKey := collectionShufflePreferenceKey("playlist", strings.TrimSpace(oldName))
	newKey := collectionShufflePreferenceKey("playlist", strings.TrimSpace(newName))
	if oldKey == newKey {
		return nil
	}
	return store.Instance.UpdateMap(collectionShuffleStoreName, func(raw map[string]interface{}) (bool, error) {
		changed := false
		preference, exists := raw[oldKey]
		if exists {
			delete(raw, oldKey)
			changed = true
		}
		if value, ok := preference.(string); ok && (value == "on" || value == "off") {
			raw[newKey] = value
			return true, nil
		}
		if _, stale := raw[newKey]; stale {
			delete(raw, newKey)
			changed = true
		}
		return changed, nil
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
