package lyricssync

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"ux-music-sidecar/internal/config"
)

const (
	sidecarRuntimeAuto   = "auto"
	sidecarRuntimePython = "python"
	sidecarRuntimeSwift  = "swift"
)

type sidecarSpec struct {
	runtimeName string
	argv        []string
	env         []string
}

func resolveSidecarArgvEnv(req *Request) ([]string, []string, error) {
	spec, err := resolveSidecarSpec(req)
	if err != nil {
		return nil, nil, err
	}
	return spec.argv, spec.env, nil
}

func resolveSidecarSpec(req *Request) (sidecarSpec, error) {
	if strings.TrimSpace(req.WhisperModel) == "" {
		req.WhisperModel = defaultWhisperModel
	}

	preference := normaliseSidecarRuntimePreference(os.Getenv(envLyricsRuntime))
	if shouldUseSwiftRuntime(runtime.GOOS, preference, swiftSidecarAvailable()) {
		return resolveSwiftSidecarSpec(req)
	}
	if preference == sidecarRuntimeSwift {
		return resolveSwiftSidecarSpec(req)
	}
	return resolvePythonSidecarSpec(req)
}

func normaliseSidecarRuntimePreference(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", sidecarRuntimeAuto:
		return sidecarRuntimeAuto
	case sidecarRuntimePython:
		return sidecarRuntimePython
	case sidecarRuntimeSwift:
		return sidecarRuntimeSwift
	default:
		return sidecarRuntimeAuto
	}
}

func shouldUseSwiftRuntime(goos string, preference string, swiftConfigured bool) bool {
	switch normaliseSidecarRuntimePreference(preference) {
	case sidecarRuntimeSwift:
		return goos == "darwin"
	case sidecarRuntimeAuto:
		return goos == "darwin" && swiftConfigured
	default:
		return false
	}
}

func swiftSidecarAvailable() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	if _, ok := configuredSwiftSidecarBinary(); ok {
		return true
	}
	if _, err := DevelopmentSwiftPkgRoot(); err != nil {
		return false
	}
	_, err := exec.LookPath("swift")
	return err == nil
}

func configuredSwiftSidecarBinary() (string, bool) {
	bin := strings.TrimSpace(os.Getenv(envSwiftSidecarBin))
	if bin == "" {
		return developmentSwiftBuiltBinary()
	}
	fi, err := os.Stat(bin)
	if err != nil || fi.IsDir() {
		return developmentSwiftBuiltBinary()
	}
	return filepath.Clean(bin), true
}

func developmentSwiftBuiltBinary() (string, bool) {
	pkgRoot, err := DevelopmentSwiftPkgRoot()
	if err != nil {
		return "", false
	}
	candidates := []string{
		filepath.Join(pkgRoot, ".build", "release", "lyrics-sync-swift"),
		filepath.Join(pkgRoot, ".build", "debug", "lyrics-sync-swift"),
	}
	for _, candidate := range candidates {
		fi, err := os.Stat(candidate)
		if err != nil || fi.IsDir() {
			continue
		}
		return filepath.Clean(candidate), true
	}
	return "", false
}

func resolveSwiftSidecarSpec(req *Request) (sidecarSpec, error) {
	if runtime.GOOS != "darwin" {
		return sidecarSpec{}, fmt.Errorf("Swift sidecar は macOS 専用です")
	}

	env, err := resolveSharedSidecarEnv(req)
	if err != nil {
		return sidecarSpec{}, err
	}

	if bin, ok := configuredSwiftSidecarBinary(); ok {
		return sidecarSpec{
			runtimeName: sidecarRuntimeSwift,
			argv:        []string{bin, "--request", "-"},
			env:         env,
		}, nil
	}

	pkgRoot, err := DevelopmentSwiftPkgRoot()
	if err != nil {
		return sidecarSpec{}, err
	}
	swiftExe, err := exec.LookPath("swift")
	if err != nil {
		return sidecarSpec{}, fmt.Errorf("Swift 実行環境が見つかりません: %w", err)
	}

	return sidecarSpec{
		runtimeName: sidecarRuntimeSwift,
		argv: []string{
			swiftExe,
			"run",
			"--package-path",
			pkgRoot,
			"lyrics-sync-swift",
			"--request",
			"-",
		},
		env: env,
	}, nil
}

func resolvePythonSidecarSpec(req *Request) (sidecarSpec, error) {
	pythonPkg, err := DevelopmentPythonPkgRoot()
	if err != nil {
		return sidecarSpec{}, err
	}

	pythonExe, err := ResolveLyricsSidecarPythonExe(pythonPkg)
	if err != nil {
		return sidecarSpec{}, err
	}
	if !lyricsDummyModeEnabledInEnv() {
		if err := verifyLyricsSidecarPython(pythonExe); err != nil {
			return sidecarSpec{}, err
		}
	}

	argv, err := ResolvePythonArgv(pythonExe)
	if err != nil {
		return sidecarSpec{}, err
	}

	env, err := resolveSharedSidecarEnv(req)
	if err != nil {
		return sidecarSpec{}, err
	}
	env = append(env, fmt.Sprintf("%s=%s", envPythonPath, pythonPkg))

	return sidecarSpec{
		runtimeName: sidecarRuntimePython,
		argv:        argv,
		env:         env,
	}, nil
}

func resolveSharedSidecarEnv(req *Request) ([]string, error) {
	consent := req.AllowModelDownload
	if !consent {
		consent = loadModelConsentFromStore()
	}

	download := hfDownloadNone
	if consent {
		download = hfDownloadAllow
	}

	modelCache := filepath.Join(config.GetUserDataPath(), "lyrics-sync-models")
	if err := os.MkdirAll(modelCache, 0755); err != nil {
		return nil, fmt.Errorf("モデルキャッシュ作成: %w", err)
	}

	env := os.Environ()
	env = append(env,
		fmt.Sprintf("%s=%s", envModelCache, modelCache),
		fmt.Sprintf("%s=%s", envHF_DOWNLOAD, download),
	)
	if p := strings.TrimSpace(config.FFmpegPath); p != "" {
		env = append(env, "UX_MUSIC_FFMPEG="+p)
	}
	if p := strings.TrimSpace(config.FFprobePath); p != "" {
		env = append(env, "UX_MUSIC_FFPROBE="+p)
	}
	return env, nil
}

func DevelopmentSwiftPkgRoot() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for dir := wd; ; dir = filepath.Dir(dir) {
		candidate := filepath.Join(dir, "swift", "lyrics-sync")
		if st, err := os.Stat(filepath.Join(candidate, "Package.swift")); err == nil && !st.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}
	return "", fmt.Errorf("swift/lyrics-sync/Package.swift not found under cwd ancestors")
}
