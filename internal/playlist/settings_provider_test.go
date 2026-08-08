package playlist

import (
	"testing"
	"ux-music-sidecar/internal/config"
)

// fakeSettingsProvider implements SettingsProvider for tests, avoiding any
// dependency on internal/store.
type fakeSettingsProvider struct {
	maps map[string]map[string]interface{}
}

func (f *fakeSettingsProvider) LoadMap(name string) (map[string]interface{}, error) {
	if m, ok := f.maps[name]; ok {
		return m, nil
	}
	return map[string]interface{}{}, nil
}

func TestGetAllPlaylistsUsesInjectedSettingsProvider(t *testing.T) {
	dir := t.TempDir()
	oldUserDataPath := config.GetUserDataPath()
	config.SetUserDataPath(dir)
	t.Cleanup(func() { config.SetUserDataPath(oldUserDataPath) })

	playlistsDir := GetPlaylistsDir()
	for _, name := range []string{"b.m3u8", "a.m3u8"} {
		if err := writeM3U8(playlistsDir+"/"+name, nil); err != nil {
			t.Fatalf("failed to seed playlist file %s: %v", name, err)
		}
	}

	provider := &fakeSettingsProvider{
		maps: map[string]map[string]interface{}{
			PlaylistOrderFileName: {
				"order": []interface{}{"a", "b"},
			},
		},
	}

	oldProvider := settingsProvider
	SetSettingsProvider(provider)
	t.Cleanup(func() { settingsProvider = oldProvider })

	names, err := GetAllPlaylists()
	if err != nil {
		t.Fatalf("GetAllPlaylists returned error: %v", err)
	}

	if len(names) != 2 || names[0] != "a" || names[1] != "b" {
		t.Errorf("GetAllPlaylists() = %v, want order [a b] from injected provider", names)
	}
}
