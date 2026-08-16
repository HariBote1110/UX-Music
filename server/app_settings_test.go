package server

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGetArtworkAsDataURLRejectsTraversal(t *testing.T) {
	// userDataPath / store.Instance はプロセスグローバルなので、
	// テスト終了時に必ず元へ戻すヘルパー経由で差し替える。
	tmpDir := newTempUserDataStore(t)

	if err := os.MkdirAll(filepath.Join(tmpDir, "Artworks"), 0755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(tmpDir, "outside.jpg")
	if err := os.WriteFile(outside, []byte("not artwork"), 0644); err != nil {
		t.Fatal(err)
	}

	got, err := (&App{}).GetArtworkAsDataURL("../outside.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Fatalf("GetArtworkAsDataURL returned data for traversal path: %q", got)
	}
}
