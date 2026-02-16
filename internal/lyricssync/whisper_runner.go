package lyricssync

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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
	type rawTranscriptionSegment struct {
		Timestamps struct {
			From string `json:"from"`
			To   string `json:"to"`
		} `json:"timestamps"`
		Offsets struct {
			From *int64 `json:"from"`
			To   *int64 `json:"to"`
		} `json:"offsets"`
		Text string `json:"text"`
	}
	type transcriptionPayload struct {
		Transcription []rawTranscriptionSegment `json:"transcription"`
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

	if len(rawSegments) == 0 {
		var transcribed transcriptionPayload
		if err := json.Unmarshal(raw, &transcribed); err != nil {
			return nil, fmt.Errorf("whisper JSON の解析に失敗しました: %w", err)
		}

		if len(transcribed.Transcription) > 0 {
			segments := make([]whisperSegment, 0, len(transcribed.Transcription))
			for _, ts := range transcribed.Transcription {
				start := 0.0
				end := 0.0

				if ts.Offsets.From != nil {
					start = float64(*ts.Offsets.From) / 1000.0
				} else if parsed, ok := parseTimestampString(ts.Timestamps.From); ok {
					start = parsed
				}
				if ts.Offsets.To != nil {
					end = float64(*ts.Offsets.To) / 1000.0
				} else if parsed, ok := parseTimestampString(ts.Timestamps.To); ok {
					end = parsed
				}

				segments = append(segments, whisperSegment{
					Start: start,
					End:   end,
					Text:  strings.TrimSpace(ts.Text),
				})
			}
			return segments, nil
		}
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

func parseTimestampString(value string) (float64, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, false
	}

	parts := strings.Split(trimmed, ":")
	if len(parts) != 3 {
		return 0, false
	}

	hours, errH := strconv.Atoi(parts[0])
	minutes, errM := strconv.Atoi(parts[1])
	if errH != nil || errM != nil {
		return 0, false
	}

	secParts := strings.Split(parts[2], ",")
	if len(secParts) != 2 {
		return 0, false
	}
	seconds, errS := strconv.Atoi(secParts[0])
	millis, errMs := strconv.Atoi(secParts[1])
	if errS != nil || errMs != nil {
		return 0, false
	}

	total := float64(hours*3600+minutes*60+seconds) + float64(millis)/1000.0
	return total, true
}

func mapLanguage(language string) string {
	if strings.TrimSpace(language) == "" {
		return "auto"
	}
	switch strings.TrimSpace(strings.ToLower(language)) {
	case "auto-ja", "ja":
		return "ja"
	case "auto-en", "en":
		return "en"
	case "auto":
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
