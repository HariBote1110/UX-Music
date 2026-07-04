package lyricssync

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// SettingsProvider abstracts loading a persisted settings map, decoupling
// this package from internal/store's concrete singleton implementation.
type SettingsProvider interface {
	LoadMap(name string) (map[string]interface{}, error)
}

var settingsProvider SettingsProvider

// SetSettingsProvider injects the SettingsProvider implementation used to
// read persisted settings (e.g. lyrics sync model consent). Callers
// (e.g. server/) should call this during initialisation, passing
// internal/store's Instance or an equivalent implementation.
func SetSettingsProvider(provider SettingsProvider) {
	settingsProvider = provider
}

const (
	envPythonPath       = "PYTHONPATH"
	envModelCache       = "UX_MUSIC_MODEL_CACHE"
	envHF_DOWNLOAD      = "UX_MUSIC_HF_DOWNLOAD"
	envLyricsRuntime    = "UX_MUSIC_LYRICS_SYNC_RUNTIME"
	envSwiftSidecarBin  = "UX_MUSIC_LYRICS_SYNC_SWIFT_BIN"
	hfDownloadNone      = "none"
	hfDownloadAllow     = "allow"
	settingsConsentKey  = "lyricsSyncModelConsent"
	defaultWhisperModel = "medium"
)

// Syncer runs the lyrics sync Python pipeline (stdin JSON Request → stdout JSON Result).
type Syncer struct {
	mu sync.Mutex

	onProgress ProgressSink
}

func NewSyncer() *Syncer {
	return &Syncer{}
}

func (s *Syncer) SetProgressHandler(handler ProgressSink) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onProgress = handler
}

func (s *Syncer) progressFn() ProgressSink {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.onProgress
}

// Sync validates the request and runs the sidecar subprocess.
func (s *Syncer) Sync(req Request) Result {
	req = sanitiseRequest(req)

	if err := validateRequest(req); err != nil {
		log.Printf("[LyricsAutoSync] request invalid: %v", err)
		return Result{Success: false, Error: err.Error()}
	}

	audioDuration, _ := probeAudioDuration(req.SongPath)
	preference := normaliseSidecarRuntimePreference(os.Getenv(envLyricsRuntime))
	spec, err := resolveSidecarSpec(&req)
	if err != nil {
		log.Printf("[LyricsAutoSync] resolve sidecar: %v", err)
		return failSync(fmt.Errorf("lyrics sync sidecar: %w", err))
	}

	timeout := computeSidecarTimeout(audioDuration)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	var onProgress ProgressSink
	if p := s.progressFn(); p != nil {
		onProgress = p
	}

	res, err := RunSidecar(ctx, req, spec.argv, spec.env, onProgress, nil)
	if err != nil {
		log.Printf("[LyricsAutoSync] RunSidecar error: %v", err)
		if ctx.Err() == context.DeadlineExceeded {
			return failSync(fmt.Errorf("自動同期がタイムアウトしました（%s）", timeout))
		}
		if shouldAutoFallbackToPython(spec, preference, err) {
			log.Printf("[LyricsAutoSync] Swift sidecar から Python sidecar へフォールバックします")
			pythonSpec, pyErr := resolvePythonSidecarSpec(&req)
			if pyErr != nil {
				log.Printf("[LyricsAutoSync] resolve python fallback: %v", pyErr)
				return failSync(err)
			}
			fallbackCtx, fallbackCancel, ok := deriveFallbackContext(ctx, timeout)
			if !ok {
				log.Printf("[LyricsAutoSync] Python フォールバックに必要な残り時間が不足しています")
				return failSync(err)
			}
			defer fallbackCancel()
			res, err = RunSidecar(fallbackCtx, req, pythonSpec.argv, pythonSpec.env, onProgress, nil)
			if err == nil {
				return res
			}
			if fallbackCtx.Err() == context.DeadlineExceeded {
				return failSync(fmt.Errorf("自動同期がタイムアウトしました（%s）", timeout))
			}
			log.Printf("[LyricsAutoSync] python fallback failed: %v", err)
		}
		return failSync(err)
	}
	if !res.Success && strings.TrimSpace(res.Error) != "" {
		log.Printf("[LyricsAutoSync] sidecar failure: matchedCount=%d error=%s", res.MatchedCount, strings.TrimSpace(res.Error))
		return res
	}
	return res
}

func shouldAutoFallbackToPython(spec sidecarSpec, preference string, err error) bool {
	if preference != sidecarRuntimeAuto || spec.runtimeName != sidecarRuntimeSwift {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return false
	}
	switch classifySidecarFailure(err) {
	case sidecarFailureStart, sidecarFailureEmptyStdout, sidecarFailureDecode:
		return true
	default:
		return false
	}
}

func deriveFallbackContext(parent context.Context, totalTimeout time.Duration) (context.Context, context.CancelFunc, bool) {
	deadline, ok := parent.Deadline()
	if !ok {
		ctx, cancel := context.WithTimeout(parent, totalTimeout)
		return ctx, cancel, true
	}

	remaining := time.Until(deadline)
	const minFallbackWindow = 2 * time.Minute
	if remaining < minFallbackWindow {
		return nil, nil, false
	}
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	return ctx, cancel, true
}

func sanitiseRequest(req Request) Request {
	req.SongPath = strings.TrimSpace(req.SongPath)
	if strings.TrimSpace(req.Profile) == "" {
		req.Profile = "fast"
	}
	req.Language = normaliseLanguageHint(req.Language)

	sanitisedLines := make([]string, len(req.Lines))
	copy(sanitisedLines, req.Lines)
	req.Lines = sanitisedLines
	return req
}

func normaliseLanguageHint(language string) string {
	clean := strings.ToLower(strings.TrimSpace(language))
	switch clean {
	case "", "auto":
		return "auto"
	case "auto-ja":
		return "ja"
	case "auto-en":
		return "en"
	case "ja", "en":
		return clean
	default:
		return clean
	}
}

func validateRequest(req Request) error {
	if req.SongPath == "" {
		return fmt.Errorf("songPath が空です")
	}
	if _, err := os.Stat(req.SongPath); err != nil {
		return fmt.Errorf("音声ファイルが見つかりません: %w", err)
	}
	if len(req.Lines) == 0 {
		return fmt.Errorf("歌詞行がありません")
	}
	hasContent := false
	for _, line := range req.Lines {
		if strings.TrimSpace(line) != "" {
			hasContent = true
			break
		}
	}
	if !hasContent {
		return fmt.Errorf("歌詞行がすべて空です")
	}
	return nil
}

func failSync(err error) Result {
	msg := err.Error()
	return Result{
		Success: false,
		Error:   msg,
	}
}

func computeSidecarTimeout(durationSeconds float64) time.Duration {
	if durationSeconds <= 0 {
		return 35 * time.Minute
	}

	computed := time.Duration(durationSeconds*5.5+420) * time.Second
	const minDur = 8 * time.Minute
	const maxDur = 110 * time.Minute
	if computed < minDur {
		return minDur
	}
	if computed > maxDur {
		return maxDur
	}
	return computed
}

func loadModelConsentFromStore() bool {
	if settingsProvider == nil {
		return false
	}
	m, err := settingsProvider.LoadMap("settings")
	if err != nil {
		return false
	}
	v, ok := m[settingsConsentKey]
	if !ok {
		return false
	}
	b, ok := v.(bool)
	return ok && b
}
