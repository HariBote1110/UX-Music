package lyricssync

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"ux-music-sidecar/internal/config"
)

type Syncer struct {
	runner *WhisperRunner
}

func NewSyncer() *Syncer {
	return &Syncer{
		runner: NewWhisperRunner(),
	}
}

func (s *Syncer) Sync(req Request) Result {
	sanitised := sanitiseRequest(req)
	if err := validateRequest(sanitised); err != nil {
		return Result{
			Success: false,
			Error:   err.Error(),
		}
	}

	logAutoSync("同期開始: path=%s lines=%d profile=%s language=%s", sanitised.SongPath, len(sanitised.Lines), sanitised.Profile, sanitised.Language)

	workDir, err := os.MkdirTemp("", "uxmusic-lyrics-sync-*")
	if err != nil {
		return failResult(fmt.Errorf("一時ディレクトリの作成に失敗しました: %w", err))
	}
	defer os.RemoveAll(workDir)

	wavPath := filepath.Join(workDir, "input.wav")
	if err := extractMonoWAV(sanitised.SongPath, wavPath); err != nil {
		return failResult(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	segments, err := s.runner.Run(ctx, wavPath, sanitised)
	if err != nil {
		return failResult(err)
	}

	aligned, matchedCount := alignLines(sanitised.Lines, segments)
	logAutoSync("同期完了: matched=%d total=%d", matchedCount, len(aligned))
	return Result{
		Success:      true,
		Lines:        aligned,
		MatchedCount: matchedCount,
	}
}

func failResult(err error) Result {
	logAutoSync("同期失敗: %v", err)
	return Result{
		Success: false,
		Error:   err.Error(),
	}
}

func sanitiseRequest(req Request) Request {
	req.SongPath = strings.TrimSpace(req.SongPath)
	if strings.TrimSpace(req.Profile) == "" {
		req.Profile = "fast"
	}
	if strings.TrimSpace(req.Language) == "" {
		req.Language = "auto-ja"
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

func extractMonoWAV(inputPath string, outputPath string) error {
	ffmpegPath, err := resolveFFmpegPath()
	if err != nil {
		return err
	}

	args := []string{
		"-y",
		"-i", inputPath,
		"-vn",
		"-ac", "1",
		"-ar", "16000",
		outputPath,
	}

	logAutoSync("ffmpeg実行: %s %s", ffmpegPath, strings.Join(args, " "))
	cmd := exec.Command(ffmpegPath, args...)
	output, runErr := cmd.CombinedOutput()
	if runErr != nil {
		return fmt.Errorf("ffmpeg で音声抽出に失敗しました: %v (%s)", runErr, strings.TrimSpace(string(output)))
	}
	return nil
}

func resolveFFmpegPath() (string, error) {
	if strings.TrimSpace(config.FFmpegPath) != "" {
		if _, err := os.Stat(config.FFmpegPath); err == nil {
			return config.FFmpegPath, nil
		}
	}
	path, err := exec.LookPath("ffmpeg")
	if err != nil {
		return "", fmt.Errorf("ffmpeg が見つかりません")
	}
	return path, nil
}

func logAutoSync(format string, args ...interface{}) {
	fmt.Printf("[Lyrics AutoSync] "+format+"\n", args...)
}
