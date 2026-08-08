package llamasrv

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// Config tells Server how to spawn llama-server.
type Config struct {
	BinaryPath string // path to `llama-server` (defaults to "llama-server" on PATH)
	ModelPath  string // GGUF file
	Host       string // defaults to 127.0.0.1
	Port       int    // defaults to 18080
	ContextLen int    // -c, defaults to 4096
	NGL        int    // --n-gpu-layers, -1 = max (default), 0 = CPU only
	LogPath    string // optional: stderr+stdout redirected here
}

// Server manages a llama-server child process.
//
// Lifecycle:
//
//	srv, _ := NewServer(cfg)
//	if err := srv.Start(ctx); err != nil { … }
//	defer srv.Stop()
//	client := srv.Client()
//
// Start is idempotent: calling it while running returns nil.
type Server struct {
	cfg Config

	mu      sync.Mutex
	cmd     *exec.Cmd
	logFile *os.File
	client  *Client
}

// NewServer validates cfg and applies defaults.
func NewServer(cfg Config) (*Server, error) {
	if cfg.ModelPath == "" {
		return nil, fmt.Errorf("llamasrv: ModelPath required")
	}
	if fi, err := os.Stat(cfg.ModelPath); err != nil {
		return nil, fmt.Errorf("llamasrv: model not found: %w", err)
	} else if fi.IsDir() {
		return nil, fmt.Errorf("llamasrv: model path is a directory: %s", cfg.ModelPath)
	}
	if cfg.BinaryPath == "" {
		cfg.BinaryPath = "llama-server"
	}
	if cfg.Host == "" {
		cfg.Host = "127.0.0.1"
	}
	if cfg.Port == 0 {
		cfg.Port = 18080
	}
	if cfg.ContextLen == 0 {
		cfg.ContextLen = 4096
	}
	return &Server{cfg: cfg}, nil
}

// Start launches llama-server if not already running and waits for /health.
func (s *Server) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cmd != nil && s.isAliveLocked() {
		return nil
	}

	// Reset state if a previous run left a dead cmd.
	s.cmd = nil
	if s.logFile != nil {
		_ = s.logFile.Close()
		s.logFile = nil
	}

	args := []string{
		"-m", s.cfg.ModelPath,
		"--host", s.cfg.Host,
		"--port", strconv.Itoa(s.cfg.Port),
		"-c", strconv.Itoa(s.cfg.ContextLen),
	}
	if s.cfg.NGL != 0 {
		args = append(args, "-ngl", strconv.Itoa(s.cfg.NGL))
	}

	cmd := exec.Command(s.cfg.BinaryPath, args...)
	if s.cfg.LogPath != "" {
		if err := os.MkdirAll(filepath.Dir(s.cfg.LogPath), 0o755); err != nil {
			return fmt.Errorf("llamasrv: log dir: %w", err)
		}
		f, err := os.OpenFile(s.cfg.LogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return fmt.Errorf("llamasrv: log file: %w", err)
		}
		s.logFile = f
		cmd.Stdout = f
		cmd.Stderr = f
	}
	// Put the child in its own process group so we can SIGTERM cleanly.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("llamasrv: start %s: %w", s.cfg.BinaryPath, err)
	}
	s.cmd = cmd
	s.client = NewClient(fmt.Sprintf("http://%s:%d", s.cfg.Host, s.cfg.Port))

	if err := s.waitHealthyLocked(ctx); err != nil {
		_ = s.terminateLocked()
		return err
	}
	return nil
}

func (s *Server) waitHealthyLocked(ctx context.Context) error {
	// Up to 90s for first-run model load (cold mmap on M-series ≈ 5–15s).
	deadline := time.Now().Add(90 * time.Second)
	for {
		if !s.isAliveLocked() {
			return fmt.Errorf("llamasrv: server exited before becoming healthy (log=%s)", s.cfg.LogPath)
		}
		hctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := s.client.Health(hctx)
		cancel()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("llamasrv: server not healthy within timeout: %w", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// Stop terminates the server if running. Idempotent.
func (s *Server) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.terminateLocked()
}

func (s *Server) terminateLocked() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}
	pid := s.cmd.Process.Pid

	// SIGTERM first, escalate to SIGKILL after 3s.
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		_ = s.cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = s.cmd.Process.Kill()
		<-done
	}
	_ = pid // (reserved for diagnostics)

	s.cmd = nil
	if s.logFile != nil {
		_ = s.logFile.Close()
		s.logFile = nil
	}
	return nil
}

// IsRunning returns true if the server process is alive.
func (s *Server) IsRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.isAliveLocked()
}

func (s *Server) isAliveLocked() bool {
	if s.cmd == nil || s.cmd.Process == nil {
		return false
	}
	// On Unix, signal 0 probes liveness without delivering anything.
	if err := s.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		return false
	}
	return true
}

// Client returns the HTTP client bound to this server.
// Returns nil if Start has not been called successfully yet.
func (s *Server) Client() *Client {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.client
}

// DefaultModelPath is the conventional location we download GGUF files to.
func DefaultModelPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "ux-music", "models", "gemma-4-E2B_q4_0-it.gguf")
}
