package lyricssync

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"ux-music-sidecar/internal/config"
)

const (
	lyricsSyncTimeout       = 2 * time.Minute
	minVocalMatchRatio      = 0.52
	defaultVocalFocusFilter = "highpass=f=120,lowpass=f=5200,acompressor=threshold=-18dB:ratio=3.5:attack=8:release=120:makeup=4,afftdn=nf=-20"
)

type Syncer struct {
	runner *WhisperRunner
}

type alignmentCandidate struct {
	name          string
	lines         []AlignedLine
	matchedCount  int
	avgConfidence float64
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

	plainWavPath := filepath.Join(workDir, "input.wav")
	if err := extractMonoWAV(sanitised.SongPath, plainWavPath, ""); err != nil {
		return failResult(err)
	}

	vocalWavPath := filepath.Join(workDir, "input-vocal.wav")
	vocalPrepared := true
	if err := extractMonoWAV(sanitised.SongPath, vocalWavPath, defaultVocalFocusFilter); err != nil {
		logAutoSync("ボーカル重視前処理の抽出に失敗したため通常音声へフォールバック: %v", err)
		vocalPrepared = false
	}

	ctx, cancel := context.WithTimeout(context.Background(), lyricsSyncTimeout)
	defer cancel()

	lineTargetCount := countTargetLyricLines(sanitised.Lines)
	best := alignmentCandidate{}
	bestSet := false
	var lastErr error

	if vocalPrepared {
		vocalCandidate, vocalErr := s.runAlignmentCandidate(ctx, vocalWavPath, sanitised, "vocal-focus")
		if vocalErr == nil {
			best = vocalCandidate
			bestSet = true
			if lineTargetCount > 0 {
				matchRatio := float64(vocalCandidate.matchedCount) / float64(lineTargetCount)
				logAutoSync("ボーカル重視候補: matched=%d ratio=%.3f avg=%.3f", vocalCandidate.matchedCount, matchRatio, vocalCandidate.avgConfidence)
				if matchRatio >= minVocalMatchRatio {
					logAutoSync("同期完了: candidate=%s matched=%d total=%d", best.name, best.matchedCount, len(best.lines))
					return Result{
						Success:      true,
						Lines:        best.lines,
						MatchedCount: best.matchedCount,
					}
				}
				logAutoSync("一致率が閾値(%.2f)未満のため通常音声でも再解析します", minVocalMatchRatio)
			}
		} else {
			lastErr = vocalErr
			logAutoSync("ボーカル重視候補の解析に失敗: %v", vocalErr)
		}
	}

	plainCandidate, plainErr := s.runAlignmentCandidate(ctx, plainWavPath, sanitised, "plain")
	if plainErr != nil {
		if bestSet {
			logAutoSync("通常音声候補は失敗したため、ボーカル重視候補を採用します")
			logAutoSync("同期完了: candidate=%s matched=%d total=%d", best.name, best.matchedCount, len(best.lines))
			return Result{
				Success:      true,
				Lines:        best.lines,
				MatchedCount: best.matchedCount,
			}
		}
		if lastErr != nil {
			return failResult(fmt.Errorf("ボーカル重視/通常音声の両方で失敗: vocal=%v plain=%v", lastErr, plainErr))
		}
		return failResult(plainErr)
	}

	if !bestSet || isBetterCandidate(plainCandidate, best) {
		best = plainCandidate
		bestSet = true
	}

	if !bestSet {
		return failResult(fmt.Errorf("同期候補が生成できませんでした"))
	}

	logAutoSync("同期完了: candidate=%s matched=%d total=%d", best.name, best.matchedCount, len(best.lines))
	return Result{
		Success:      true,
		Lines:        best.lines,
		MatchedCount: best.matchedCount,
	}
}

func (s *Syncer) runAlignmentCandidate(ctx context.Context, wavPath string, req Request, name string) (alignmentCandidate, error) {
	segments, err := s.runner.Run(ctx, wavPath, req)
	if err != nil {
		return alignmentCandidate{}, err
	}

	aligned, matchedCount := alignLines(req.Lines, segments)
	return alignmentCandidate{
		name:          name,
		lines:         aligned,
		matchedCount:  matchedCount,
		avgConfidence: averageMatchConfidence(aligned),
	}, nil
}

func isBetterCandidate(a alignmentCandidate, b alignmentCandidate) bool {
	if a.matchedCount != b.matchedCount {
		return a.matchedCount > b.matchedCount
	}
	if math.Abs(a.avgConfidence-b.avgConfidence) > 0.0001 {
		return a.avgConfidence > b.avgConfidence
	}
	return a.name == "vocal-focus" && b.name != "vocal-focus"
}

func averageMatchConfidence(lines []AlignedLine) float64 {
	total := 0.0
	count := 0.0
	for _, line := range lines {
		if line.Source != "match" {
			continue
		}
		total += line.Confidence
		count++
	}
	if count == 0 {
		return 0
	}
	return total / count
}

func countTargetLyricLines(lines []string) int {
	count := 0
	for _, line := range lines {
		if isInterludeLine(line) {
			continue
		}
		count++
	}
	return count
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

func extractMonoWAV(inputPath string, outputPath string, filter string) error {
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
	}
	if strings.TrimSpace(filter) != "" {
		args = append(args, "-af", filter)
	}
	args = append(args, outputPath)

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
