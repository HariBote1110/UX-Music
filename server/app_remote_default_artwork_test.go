package server

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

func TestRemoteArtworkHandler_notFoundWhenFileMissing(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Artworks"), 0o755); err != nil {
		t.Fatal(err)
	}

	id := strings.Repeat("a", 64)
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/artwork/?id="+id, nil)
	rec := httptest.NewRecorder()
	remoteArtworkHandler(rec, req)
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

// TestRemoteArtworkHandler_servesDevNamedFile reproduces the artwork 404 for
// sync-imported songs: the stored artwork filename is "dev_x-y.webp", not a
// 64-hex scanner stem. The handler must be able to serve it by that stem.
func TestRemoteArtworkHandler_servesDevNamedFile(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	artworksDir := filepath.Join(tmp, "Artworks")
	if err := os.MkdirAll(artworksDir, 0o755); err != nil {
		t.Fatal(err)
	}

	const stem = "dev_x-y"
	const content = "fake-webp-bytes"
	if err := os.WriteFile(filepath.Join(artworksDir, stem+".webp"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/artwork/?id="+stem, nil)
	rec := httptest.NewRecorder()
	remoteArtworkHandler(rec, req)
	res := rec.Result()
	t.Cleanup(func() { _ = res.Body.Close() })

	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d want 200", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	if string(body) != content {
		t.Fatalf("body %q want %q", body, content)
	}
}

// TestRemoteArtworkHandler_rejectsPathTraversal ensures the widened ID
// charset (now accepting non-hex dev_/custom_ stems) cannot be abused for
// path traversal or hidden-file probing.
func TestRemoteArtworkHandler_rejectsPathTraversal(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Artworks"), 0o755); err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{"../evil", "..%2Fevil", ".hidden"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/remote/artwork/?id="+strings.ReplaceAll(id, "/", "%2F"), nil)
		rec := httptest.NewRecorder()
		remoteArtworkHandler(rec, req)
		res := rec.Result()
		if res.StatusCode != http.StatusForbidden {
			t.Fatalf("id %q: status %d want 403", id, res.StatusCode)
		}
		_ = res.Body.Close()
	}
}
