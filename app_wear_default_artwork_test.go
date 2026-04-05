package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ux-music-sidecar/internal/config"
)

func TestWearArtworkHandler_notFoundWhenFileMissing(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Artworks"), 0o755); err != nil {
		t.Fatal(err)
	}

	id := strings.Repeat("a", 64)
	req := httptest.NewRequest(http.MethodGet, "/wear/artwork/?id="+id, nil)
	rec := httptest.NewRecorder()
	wearArtworkHandler(rec, req)
	res := rec.Result()
	t.Cleanup(func() { _ = res.Body.Close() })

	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d want 404", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	if len(body) > 4096 {
		t.Fatalf("404 body unexpectedly large (%d bytes)", len(body))
	}
}
