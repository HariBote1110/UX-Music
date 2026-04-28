package lyricssync

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

const (
	envPythonPath       = "PYTHONPATH"
	envModelCache       = "UX_MUSIC_MODEL_CACHE"
	envHF_DOWNLOAD      = "UX_MUSIC_HF_DOWNLOAD"
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

	argv, sidecarEnv, err := resolveSidecarArgvEnv(&req)
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

	res, err := RunSidecar(ctx, req, argv, sidecarEnv, onProgress, nil)
	if err != nil {
		log.Printf("[LyricsAutoSync] RunSidecar error: %v", err)
		if ctx.Err() == context.DeadlineExceeded {
			return failSync(fmt.Errorf("自動同期がタイムアウトしました（%s）", timeout))
		}
		return failSync(err)
	}
	if !res.Success && strings.TrimSpace(res.Error) != "" {
		log.Printf("[LyricsAutoSync] sidecar failure: matchedCount=%d error=%s", res.MatchedCount, strings.TrimSpace(res.Error))
		return res
	}
	return res
}

func sanitiseRequest(req Request) Request {
	req.SongPath = strings.TrimSpace(req.SongPath)
	if strings.TrimSpace(req.Profile) == "" {
		req.Profile = "fast"
	}
	if strings.TrimSpace(req.Language) == "" {
		req.Language = "auto"
	}

	sanitisedLines := make([]string, len(req.Lines))
	copy(sanitisedLines, req.Lines)
	req.Lines = sanitisedLines
	return req
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

func resolveSidecarArgvEnv(req *Request) ([]string, []string, error) {
	pythonPkg, err := DevelopmentPythonPkgRoot()
	if err != nil {
		return nil, nil, err
	}

	pythonExe, err := ResolveLyricsSidecarPythonExe(pythonPkg)
	if err != nil {
		return nil, nil, err
	}

	argv, err := ResolvePythonArgv(pythonExe)
	if err != nil {
		return nil, nil, err
	}

	consent := req.AllowModelDownload
	if !consent {
		consent = loadModelConsentFromStore()
	}

	download := hfDownloadNone
	if consent {
		download = hfDownloadAllow
	}

	modelCache := filepath.Join(config.GetUserDataPath(), "lyrics-sync-models")
	_ = os.MkdirAll(modelCache, 0755)

	env := os.Environ()
	env = append(env,
		fmt.Sprintf("%s=%s", envPythonPath, pythonPkg),
		fmt.Sprintf("%s=%s", envModelCache, modelCache),
		fmt.Sprintf("%s=%s", envHF_DOWNLOAD, download),
	)
	if p := strings.TrimSpace(config.FFmpegPath); p != "" {
		env = append(env, "UX_MUSIC_FFMPEG="+p)
	}
	if p := strings.TrimSpace(config.FFprobePath); p != "" {
		env = append(env, "UX_MUSIC_FFPROBE="+p)
	}

	if strings.TrimSpace(req.WhisperModel) == "" {
		req.WhisperModel = defaultWhisperModel
	}

	return argv, env, nil
}

func loadModelConsentFromStore() bool {
	raw, err := store.Instance.Load("settings")
	if err != nil || raw == nil {
		return false
	}
	m, ok := raw.(map[string]interface{})
	if !ok {
		return false
	}
	v, ok := m[settingsConsentKey]
	if !ok {
		return false
	}
	b, ok := v.(bool)
	return ok && b
}
