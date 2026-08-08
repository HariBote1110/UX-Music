package llamasrv

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewServer_RejectsMissingModel(t *testing.T) {
	_, err := NewServer(Config{ModelPath: ""})
	if err == nil {
		t.Fatal("expected error for empty ModelPath")
	}
	_, err = NewServer(Config{ModelPath: filepath.Join(t.TempDir(), "nope.gguf")})
	if err == nil {
		t.Fatal("expected error for non-existent model")
	}
}

func TestNewServer_RejectsDirectoryAsModel(t *testing.T) {
	_, err := NewServer(Config{ModelPath: t.TempDir()})
	if err == nil {
		t.Fatal("expected error for dir-as-model")
	}
}

func TestNewServer_AppliesDefaults(t *testing.T) {
	dir := t.TempDir()
	modelPath := filepath.Join(dir, "fake.gguf")
	if err := os.WriteFile(modelPath, []byte("dummy"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, err := NewServer(Config{ModelPath: modelPath})
	if err != nil {
		t.Fatal(err)
	}
	if srv.cfg.BinaryPath != "llama-server" {
		t.Errorf("default BinaryPath: %q", srv.cfg.BinaryPath)
	}
	if srv.cfg.Host != "127.0.0.1" {
		t.Errorf("default Host: %q", srv.cfg.Host)
	}
	if srv.cfg.Port != 18080 {
		t.Errorf("default Port: %d", srv.cfg.Port)
	}
	if srv.cfg.ContextLen != 4096 {
		t.Errorf("default ContextLen: %d", srv.cfg.ContextLen)
	}
}

func TestServer_StopBeforeStartIsNoop(t *testing.T) {
	dir := t.TempDir()
	modelPath := filepath.Join(dir, "fake.gguf")
	if err := os.WriteFile(modelPath, []byte("dummy"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, _ := NewServer(Config{ModelPath: modelPath})
	if err := srv.Stop(); err != nil {
		t.Fatalf("Stop on unstarted should be nil, got %v", err)
	}
	if srv.IsRunning() {
		t.Fatal("IsRunning should be false before Start")
	}
}

func TestDefaultModelPath_PointsAtHomeCache(t *testing.T) {
	p := DefaultModelPath()
	if filepath.Base(p) != "gemma-4-E2B_q4_0-it.gguf" {
		t.Errorf("unexpected default filename: %s", p)
	}
	if !filepath.IsAbs(p) {
		t.Errorf("default path should be absolute: %s", p)
	}
}
