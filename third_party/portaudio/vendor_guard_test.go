package portaudio

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNoPkgConfigDirective(t *testing.T) {
	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || strings.HasPrefix(path, "portaudio/") {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		directive := "#cgo " + "pkg-config"
		if strings.Contains(string(data), directive) {
			t.Errorf("pkg-config directive found in %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
