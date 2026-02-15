package lyricssync

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/config"
)

const (
	envCLIPath   = "UXMUSIC_LYRICS_SYNC_CLI"
	envModelPath = "UXMUSIC_LYRICS_SYNC_MODEL"
)

type WhisperRunner struct {
	cliPath        string
	modelPath      string
	coreMLModelDir string
}

func NewWhisperRunner() *WhisperRunner {
	return &WhisperRunner{}
}

func (r *WhisperRunner) Run(ctx context.Context, wavPath string, req Request) ([]whisperSegment, error) {
	cliPath, err := r.resolveCLIPath()
	if err != nil {
		return nil, err
	}
	modelPath, err := r.resolveModelPath()
	if err != nil {
		return nil, err
	}
	coreMLDir, err := r.resolveCoreMLModelDir(modelPath)
	if err != nil {
		return nil, err
	}

	if _, err := os.Stat(wavPath); err != nil {
		return nil, fmt.Errorf("入力WAVが見つかりません: %w", err)
	}

	outputDir := filepath.Dir(wavPath)
	outputBase := filepath.Join(outputDir, "whisper-output")
	outputJSON := outputBase + ".json"

	_ = os.Remove(outputJSON)

	args := []string{
		"-m", modelPath,
		"-f", wavPath,
		"-oj",
		"-of", outputBase,
		"-l", mapLanguage(req.Language),
	}

	logAutoSync("whisper実行: cli=%s model=%s coreml=%s", cliPath, modelPath, coreMLDir)
	cmd := exec.CommandContext(ctx, cliPath, args...)
	cmd.Env = append(os.Environ(), "WHISPER_COREML_MODEL_PATH="+coreMLDir)

	output, runErr := cmd.CombinedOutput()
	if runErr != nil {
		return nil, fmt.Errorf("whisper-cli 実行に失敗しました: %v (%s)", runErr, strings.TrimSpace(string(output)))
	}

	jsonBytes, readErr := os.ReadFile(outputJSON)
	if readErr != nil {
		return nil, fmt.Errorf("whisper JSON 出力の読込に失敗しました: %w", readErr)
	}

	segments, parseErr := parseWhisperJSON(jsonBytes)
	if parseErr != nil {
		return nil, parseErr
	}

	if len(segments) == 0 {
		return nil, fmt.Errorf("whisper のセグメント結果が空です")
	}

	return segments, nil
}

func (r *WhisperRunner) resolveCLIPath() (string, error) {
	if value := strings.TrimSpace(os.Getenv(envCLIPath)); value != "" {
		if err := assertExecutablePath(value); err != nil {
			return "", fmt.Errorf("環境変数 %s のパスが無効です: %w", envCLIPath, err)
		}
		r.cliPath = value
		return value, nil
	}

	defaultPath := filepath.Join(defaultLyricsSyncDir(), "bin", "whisper-cli")
	if err := assertExecutablePath(defaultPath); err == nil {
		r.cliPath = defaultPath
		return defaultPath, nil
	}

	return "", fmt.Errorf("whisper-cli が見つかりません。%s を設定するか %s に配置してください", envCLIPath, defaultPath)
}

func (r *WhisperRunner) resolveModelPath() (string, error) {
	if value := strings.TrimSpace(os.Getenv(envModelPath)); value != "" {
		if err := assertRegularFile(value); err != nil {
			return "", fmt.Errorf("環境変数 %s のモデルが無効です: %w", envModelPath, err)
		}
		r.modelPath = value
		return value, nil
	}

	defaultPath := filepath.Join(defaultLyricsSyncDir(), "models", "ggml-base.bin")
	if err := assertRegularFile(defaultPath); err == nil {
		r.modelPath = defaultPath
		return defaultPath, nil
	}

	return "", fmt.Errorf("Whisperモデルが見つかりません。%s を設定するか %s に配置してください", envModelPath, defaultPath)
}

func (r *WhisperRunner) resolveCoreMLModelDir(modelPath string) (string, error) {
	base := strings.TrimSuffix(modelPath, filepath.Ext(modelPath))
	defaultDir := base + "-encoder.mlmodelc"

	if info, err := os.Stat(defaultDir); err == nil && info.IsDir() {
		r.coreMLModelDir = defaultDir
		return defaultDir, nil
	}

	fallbackDir := filepath.Join(defaultLyricsSyncDir(), "models", "ggml-base-encoder.mlmodelc")
	if info, err := os.Stat(fallbackDir); err == nil && info.IsDir() {
		r.coreMLModelDir = fallbackDir
		return fallbackDir, nil
	}

	return "", fmt.Errorf("CoreMLモデルが見つかりません。%s または %s を配置してください", defaultDir, fallbackDir)
}

func parseWhisperJSON(raw []byte) ([]whisperSegment, error) {
	type rawSegment struct {
		Start *float64 `json:"start"`
		End   *float64 `json:"end"`
		T0    *int64   `json:"t0"`
		T1    *int64   `json:"t1"`
		Text  string   `json:"text"`
	}

	type directPayload struct {
		Segments []rawSegment `json:"segments"`
	}
	type nestedPayload struct {
		Result struct {
			Segments []rawSegment `json:"segments"`
		} `json:"result"`
	}

	var direct directPayload
	if err := json.Unmarshal(raw, &direct); err != nil {
		return nil, fmt.Errorf("whisper JSON の解析に失敗しました: %w", err)
	}

	rawSegments := direct.Segments
	if len(rawSegments) == 0 {
		var nested nestedPayload
		if err := json.Unmarshal(raw, &nested); err != nil {
			return nil, fmt.Errorf("whisper JSON の解析に失敗しました: %w", err)
		}
		rawSegments = nested.Result.Segments
	}

	segments := make([]whisperSegment, 0, len(rawSegments))
	for _, rs := range rawSegments {
		start := 0.0
		end := 0.0

		if rs.Start != nil {
			start = *rs.Start
		} else if rs.T0 != nil {
			start = float64(*rs.T0) / 100.0
		}
		if rs.End != nil {
			end = *rs.End
		} else if rs.T1 != nil {
			end = float64(*rs.T1) / 100.0
		}

		segments = append(segments, whisperSegment{
			Start: start,
			End:   end,
			Text:  strings.TrimSpace(rs.Text),
		})
	}

	return segments, nil
}

func mapLanguage(language string) string {
	if strings.TrimSpace(language) == "" {
		return "auto"
	}
	switch strings.TrimSpace(strings.ToLower(language)) {
	case "auto-ja":
		return "auto"
	default:
		return "auto"
	}
}

func defaultLyricsSyncDir() string {
	userData := config.GetUserDataPath()
	if strings.TrimSpace(userData) != "" {
		return filepath.Join(userData, "LyricsSync")
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "ux-music", "LyricsSync")
	}
	return filepath.Join(configDir, "ux-music", "LyricsSync")
}

func assertExecutablePath(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("ディレクトリです")
	}
	return nil
}

func assertRegularFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("ディレクトリです")
	}
	return nil
}
