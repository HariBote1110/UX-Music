package lyricssync

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ProgressSink receives stderr JSON progress lines: {"stage":"","percent":0-100}.
type ProgressSink func(stage string, percent float64)

// RunSidecar spawns Python `python -m lyrics_sync --request -`, sends req as stdin JSON, parses stdout JSON as Result.
// stderr lines that are JSON objects with keys "stage" and "percent" are forwarded to onProgress (optional).
func RunSidecar(ctx context.Context, req Request, argv []string, env []string, onProgress ProgressSink, stdout io.Writer) (Result, error) {
	if len(argv) == 0 {
		return Result{}, fmt.Errorf("lyrics sync argv is empty")
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return Result{}, fmt.Errorf("marshal request: %w", err)
	}

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(payload)
	cmd.Env = env

	var outBuf strings.Builder
	if stdout != nil {
		cmd.Stdout = io.MultiWriter(&outBuf, stdout)
	} else {
		cmd.Stdout = &outBuf
	}

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return Result{}, fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return Result{}, fmt.Errorf("start lyrics_sync: %w", err)
	}

	if onProgress != nil {
		go drainProgress(stderrPipe, onProgress)
	} else {
		go func() {
			_, _ = io.Copy(io.Discard, stderrPipe)
			_ = stderrPipe.Close()
		}()
	}

	waitErr := cmd.Wait()

	raw := strings.TrimSpace(outBuf.String())
	if raw == "" {
		if waitErr != nil {
			return Result{}, fmt.Errorf("sidecar exited with empty stdout: %w", waitErr)
		}
		return Result{}, fmt.Errorf("sidecar returned empty stdout")
	}

	var parsed Result
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return Result{}, fmt.Errorf("decode result json: %w (stdout=%q stderr_err=%v)", err, truncate(raw, 200), waitErr)
	}

	if waitErr != nil && !parsed.Success {
		return parsed, nil
	}
	if waitErr != nil {
		return parsed, fmt.Errorf("sidecar: %w", waitErr)
	}
	return parsed, nil
}

func drainProgress(stderr io.ReadCloser, onProgress ProgressSink) {
	sc := bufio.NewScanner(stderr)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var ev struct {
			Stage   string  `json:"stage"`
			Percent float64 `json:"percent"`
		}
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		if onProgress != nil {
			onProgress(ev.Stage, ev.Percent)
		}
	}
	_ = stderr.Close()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ResolvePythonArgv returns exec path slices for `[pythonExe, "-m", "lyrics_sync", "--request", "-"]` when PYTHONPATH contains the lyrics_sync parent.
func ResolvePythonArgv(pythonExe string) ([]string, error) {
	if strings.TrimSpace(pythonExe) == "" {
		return nil, fmt.Errorf("python exe is blank")
	}
	return []string{pythonExe, "-m", "lyrics_sync", "--request", "-"}, nil
}

// FindDevelopmentPythonExe prefers UX_MUSIC_PYTHON, else python3 on PATH.
func FindDevelopmentPythonExe() (string, error) {
	if p := strings.TrimSpace(os.Getenv("UX_MUSIC_PYTHON")); p != "" {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p, nil
		}
	}
	return exec.LookPath("python3")
}

// DevelopmentPythonPkgRoot searches for the repository `python/` directory next to cwd or UX_MUSIC_PYTHON_PKG_PARENT.
func DevelopmentPythonPkgRoot() (string, error) {
	if p := strings.TrimSpace(os.Getenv("UX_MUSIC_PYTHON_PKG_PARENT")); p != "" {
		pp := filepath.Join(p, "python")
		if st, err := os.Stat(filepath.Join(pp, "lyrics_sync")); err == nil && st.IsDir() {
			return pp, nil
		}
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for dir := wd; ; dir = filepath.Dir(dir) {
		candidate := filepath.Join(dir, "python")
		if st, err := os.Stat(filepath.Join(candidate, "lyrics_sync")); err == nil && st.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}
	return "", fmt.Errorf("python/lyrics_sync not found under cwd ancestors")
}
