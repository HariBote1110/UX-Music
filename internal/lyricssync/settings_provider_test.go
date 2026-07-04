package lyricssync

import "testing"

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

func TestLoadModelConsentFromStoreUsesInjectedSettingsProvider(t *testing.T) {
	provider := &fakeSettingsProvider{
		maps: map[string]map[string]interface{}{
			"settings": {
				settingsConsentKey: true,
			},
		},
	}

	oldProvider := settingsProvider
	SetSettingsProvider(provider)
	t.Cleanup(func() { settingsProvider = oldProvider })

	if !loadModelConsentFromStore() {
		t.Errorf("loadModelConsentFromStore() = false, want true from injected provider")
	}
}

func TestLoadModelConsentFromStoreDefaultsFalseWithoutProvider(t *testing.T) {
	oldProvider := settingsProvider
	settingsProvider = nil
	t.Cleanup(func() { settingsProvider = oldProvider })

	if loadModelConsentFromStore() {
		t.Errorf("loadModelConsentFromStore() = true, want false when no provider is set")
	}
}
