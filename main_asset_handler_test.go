package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

func TestAssetHandlerRejectsUnregisteredSafeMediaPath(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

	outside := filepath.Join(tmpDir, "outside.mp4")
	if err := os.WriteFile(outside, []byte("secret"), 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/safe-media/"+stringsTrimLeadingSlashForTest(outside), nil)
	rec := httptest.NewRecorder()
	newAssetHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d want=%d", rec.Code, http.StatusForbidden)
	}
}

func TestAssetHandlerServesRegisteredSafeMediaWithReservedCharacters(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

	mediaPath := filepath.Join(tmpDir, "song ? 100%.mp4")
	if err := os.WriteFile(mediaPath, []byte("video"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := store.Instance.Save("library", []interface{}{
		map[string]interface{}{"id": "song-1", "path": mediaPath},
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/safe-media/"+escapePathForTest(mediaPath), nil)
	rec := httptest.NewRecorder()
	newAssetHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("code=%d want=%d body=%q", rec.Code, http.StatusOK, rec.Body.String())
	}
	if rec.Body.String() != "video" {
		t.Fatalf("body=%q", rec.Body.String())
	}
}

func TestAssetHandlerRejectsSafeArtworkTraversal(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

	if err := os.MkdirAll(filepath.Join(tmpDir, "Artworks"), 0755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(tmpDir, "outside.jpg")
	if err := os.WriteFile(outside, []byte("image"), 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/safe-artwork/../outside.jpg", nil)
	rec := httptest.NewRecorder()
	newAssetHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("code=%d want=%d", rec.Code, http.StatusForbidden)
	}
}

func TestAssetHandlerServesSafeArtworkWithEscapedSpace(t *testing.T) {
	tmpDir := t.TempDir()
	config.SetUserDataPath(tmpDir)
	store.Instance = &store.Store{}

	artworksDir := filepath.Join(tmpDir, "Artworks")
	if err := os.MkdirAll(artworksDir, 0755); err != nil {
		t.Fatal(err)
	}
	artworkPath := filepath.Join(artworksDir, "foo bar.jpg")
	if err := os.WriteFile(artworkPath, []byte("image"), 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/safe-artwork/foo%20bar.jpg", nil)
	rec := httptest.NewRecorder()
	newAssetHandler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("code=%d want=%d body=%q", rec.Code, http.StatusOK, rec.Body.String())
	}
	if rec.Body.String() != "image" {
		t.Fatalf("body=%q", rec.Body.String())
	}
}

func escapePathForTest(path string) string {
	return stringsTrimLeadingSlashForTest(url.PathEscape(path))
}

func stringsTrimLeadingSlashForTest(path string) string {
	for len(path) > 0 && (path[0] == '/' || path[0] == '\\') {
		path = path[1:]
	}
	return path
}
