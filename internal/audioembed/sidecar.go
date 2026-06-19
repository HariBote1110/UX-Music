package audioembed

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
	"runtime"
	"strings"
)

// Request is the JSON payload sent to `python -m audio_embed --request -`.
// Audio mode: set SongPath or SongPaths. Text mode: set Text or Texts.
// Both modes may be sent in one request; the result populates the
// corresponding fields.
type Request struct {
	SongPath  string   `json:"songPath,omitempty"`
	SongPaths []string `json:"songPaths,omitempty"`
	Text      string   `json:"text,omitempty"`
	Texts     []string `json:"texts,omitempty"`
}

// SidecarEmbedding is one item in the sidecar Result.Embeddings slice.
type SidecarEmbedding struct {
	SongPath string    `json:"songPath"`
	Vector   []float32 `json:"vector"`
	Dim      int       `json:"dim"`
}

// SidecarTextEmbedding is one item in Result.TextEmbeddings.
type SidecarTextEmbedding struct {
	Text   string    `json:"text"`
	Vector []float32 `json:"vector"`
	Dim    int       `json:"dim"`
}

// Result is the JSON result returned on the sidecar's stdout.
type Result struct {
	Success        bool                   `json:"success"`
	Version        string                 `json:"version,omitempty"`
	Embeddings     []SidecarEmbedding     `json:"embeddings,omitempty"`
	TextEmbeddings []SidecarTextEmbedding `json:"textEmbeddings,omitempty"`
	Error          string                 `json:"error,omitempty"`
}

// ProgressSink receives stderr JSON progress lines: {"stage":"","percent":0-100}.
type ProgressSink func(stage string, percent float64)

// RunSidecar spawns the audio_embed sidecar with the given argv/env,
// sends the request as stdin JSON, and parses stdout JSON as Result.
// stderr lines that are JSON progress events are forwarded to onProgress.
func RunSidecar(ctx context.Context, req Request, argv []string, env []string, onProgress ProgressSink) (Result, error) {
	if len(argv) == 0 {
		return Result{}, fmt.Errorf("audioembed: argv is empty")
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return Result{}, fmt.Errorf("audioembed: marshal request: %w", err)
	}

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(payload)
	cmd.Env = env

	var outBuf strings.Builder
	cmd.Stdout = &outBuf

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return Result{}, fmt.Errorf("audioembed: stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return Result{}, fmt.Errorf("audioembed: start sidecar: %w", err)
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
			return Result{}, fmt.Errorf("audioembed: sidecar exited with empty stdout: %w", waitErr)
		}
		return Result{}, fmt.Errorf("audioembed: sidecar returned empty stdout")
	}

	var parsed Result
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return Result{}, fmt.Errorf("audioembed: decode result: %w (stdout=%q)", err, truncate(raw, 200))
	}

	if waitErr != nil && !parsed.Success {
		// Sidecar reported the error in its JSON; surface that, not the exit code.
		return parsed, nil
	}
	if waitErr != nil {
		return parsed, fmt.Errorf("audioembed: sidecar wait: %w", waitErr)
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
			continue // ignore non-JSON noise (model load chatter, warnings, ...)
		}
		onProgress(ev.Stage, ev.Percent)
	}
	_ = stderr.Close()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ResolveArgv returns the standard sidecar argv: `[python, -m, audio_embed, --request, -]`.
func ResolveArgv(pythonExe string) ([]string, error) {
	if strings.TrimSpace(pythonExe) == "" {
		return nil, fmt.Errorf("audioembed: python exe is blank")
	}
	return []string{pythonExe, "-m", "audio_embed", "--request", "-"}, nil
}

// resolvePythonExe picks the interpreter to run `-m audio_embed`.
//
// Preference: UX_MUSIC_PYTHON env override → bundled python/.venv → python3 on PATH.
// Mirrors lyricssync.ResolveLyricsSidecarPythonExe for layout consistency.
func resolvePythonExe(pkgRoot string) (string, error) {
	if p := strings.TrimSpace(os.Getenv("UX_MUSIC_PYTHON")); p != "" {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return filepath.Clean(p), nil
		}
	}
	if venvPy, ok := venvInterpreterPath(pkgRoot); ok {
		return venvPy, nil
	}
	return exec.LookPath("python3")
}

func venvInterpreterPath(pkgRoot string) (string, bool) {
	var candidates []string
	if runtime.GOOS == "windows" {
		candidates = []string{filepath.Join(pkgRoot, ".venv", "Scripts", "python.exe")}
	} else {
		candidates = []string{
			filepath.Join(pkgRoot, ".venv", "bin", "python3"),
			filepath.Join(pkgRoot, ".venv", "bin", "python"),
		}
	}
	for _, c := range candidates {
		fi, err := os.Stat(c)
		if err != nil || fi.IsDir() {
			continue
		}
		return filepath.Clean(c), true
	}
	return "", false
}

// DevelopmentPythonPkgRoot finds the repository `python/` directory by walking up
// from cwd; honours UX_MUSIC_PYTHON_PKG_PARENT as override.
func DevelopmentPythonPkgRoot() (string, error) {
	if p := strings.TrimSpace(os.Getenv("UX_MUSIC_PYTHON_PKG_PARENT")); p != "" {
		pp := filepath.Join(p, "python")
		if st, err := os.Stat(filepath.Join(pp, "audio_embed")); err == nil && st.IsDir() {
			return pp, nil
		}
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for dir := wd; ; dir = filepath.Dir(dir) {
		candidate := filepath.Join(dir, "python")
		if st, err := os.Stat(filepath.Join(candidate, "audio_embed")); err == nil && st.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}
	return "", fmt.Errorf("audioembed: python/audio_embed not found under cwd ancestors")
}

// ResolveDefault returns argv and env for the default development setup
// (bundled venv + repository python/ root).
func ResolveDefault() ([]string, []string, error) {
	pkgRoot, err := DevelopmentPythonPkgRoot()
	if err != nil {
		return nil, nil, err
	}
	py, err := resolvePythonExe(pkgRoot)
	if err != nil {
		return nil, nil, err
	}
	argv, err := ResolveArgv(py)
	if err != nil {
		return nil, nil, err
	}
	env := append(os.Environ(), "PYTHONPATH="+pkgRoot)
	return argv, env, nil
}
