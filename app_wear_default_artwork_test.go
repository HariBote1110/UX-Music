package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/config"
)

func TestWearDefaultArtworkAssetEmbedded(t *testing.T) {
	t.Helper()
	data, err := assets.ReadFile(wearDefaultArtworkEmbedPath)
	if err != nil {
		t.Fatalf("embedded default artwork: %v", err)
	}
	if len(data) < 8 {
		t.Fatalf("embedded file too small (%d bytes)", len(data))
	}
	if string(data[0:8]) != "\x89PNG\r\n\x1a\n" {
		t.Fatalf("expected PNG signature, got %q", data[0:8])
	}
}

func TestWearArtworkHandler_servesEmbeddedPNGWhenFileMissing(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Artworks"), 0o755); err != nil {
		t.Fatal(err)
	}

	id := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	req := httptest.NewRequest(http.MethodGet, "/wear/artwork/?id="+id, nil)
	rec := httptest.NewRecorder()
	wearArtworkHandler(rec, req)
	res := rec.Result()
	t.Cleanup(func() { _ = res.Body.Close() })

	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d", res.StatusCode)
	}
	if got := res.Header.Get("Content-Type"); got != "image/png" {
		t.Fatalf("Content-Type %q want image/png", got)
	}
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if len(body) < 8 || string(body[0:8]) != "\x89PNG\r\n\x1a\n" {
		t.Fatalf("response body is not PNG")
	}
}
