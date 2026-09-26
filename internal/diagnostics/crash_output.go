package diagnostics

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"
)

func EnableCrashOutput(dir string) (*os.File, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "crash.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	if _, err := fmt.Fprintf(f, "=== UX-Music started %s pid=%d ===\n", time.Now().Format(time.RFC3339), os.Getpid()); err != nil {
		f.Close()
		return nil, err
	}
	if err := debug.SetCrashOutput(f, debug.CrashOptions{}); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
