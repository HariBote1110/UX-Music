package diagnostics

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnableCrashOutput(t *testing.T) {
	const guard = "UXMUSIC_CRASH_OUTPUT_TEST"
	if dir := os.Getenv(guard); dir != "" {
		log, err := EnableCrashOutput(dir)
		if err != nil {
			t.Fatal(err)
		}
		_ = log
		panic("crash output test message")
	}

	dir := t.TempDir()
	cmd := exec.Command(os.Args[0], "-test.run=^TestEnableCrashOutput$")
	cmd.Env = append(os.Environ(), guard+"="+dir)
	if err := cmd.Run(); err == nil {
		t.Fatal("child exited successfully after panic")
	}
	data, err := os.ReadFile(filepath.Join(dir, "crash.log"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)
	if !strings.Contains(content, "=== UX-Music started ") || !strings.Contains(content, "panic: crash output test message") {
		t.Fatalf("crash log missing header or panic: %q", content)
	}
}
