package lyricssync

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"ux-music-sidecar/internal/config"
)

const (
	defaultWhisperTimeout   = 6 * time.Minute
	defaultVocalMLTimeout   = 8 * time.Minute
	minWhisperTimeout       = 4 * time.Minute
	maxWhisperTimeout       = 15 * time.Minute
	minVocalMLTimeout       = 5 * time.Minute
	maxVocalMLTimeout       = 20 * time.Minute
	minVocalMatchRatio      = 0.52
	defaultVocalFocusFilter = "highpass=f=70,lowpass=f=4500,acompressor=threshold=-18dB:ratio=3.5:attack=8:release=120:makeup=4,afftdn=nf=-20"
)

type Syncer struct {
	runner *WhisperRunner
}

type alignmentCandidate struct {
	name          string
	lines         []AlignedLine
	matchedCount  int
	avgConfidence float64
	segments      []whisperSegment
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

	audioDuration, durationErr := probeAudioDuration(sanitised.SongPath)
	if durationErr != nil {
		logAutoSync("音声長の取得に失敗（既定タイムアウト使用）: %v", durationErr)
		audioDuration = 0
	}
	whisperTimeout := computeWhisperTimeout(audioDuration)
	vocalMLTimeout := computeVocalMLTimeout(audioDuration)
	logAutoSync("タイムアウト設定: whisper=%s vocalML=%s duration=%.1fs", whisperTimeout.String(), vocalMLTimeout.String(), audioDuration)

	plainWavPath := filepath.Join(workDir, "input.wav")
	if err := extractMonoWAV(sanitised.SongPath, plainWavPath, ""); err != nil {
		return failResult(err)
	}

	vocalMLWavPath := filepath.Join(workDir, "input-vocal-ml.wav")
	vocalMLPrepared := false
	vocalMLCtx, vocalMLCancel := context.WithTimeout(context.Background(), vocalMLTimeout)
	if err := extractVocalWithML(vocalMLCtx, sanitised.SongPath, workDir, vocalMLWavPath); err != nil {
		logAutoSync("MLボーカル抽出は利用できないためフォールバックします: %v", err)
	} else {
		vocalMLPrepared = true
	}
	vocalMLCancel()

	vocalWavPath := filepath.Join(workDir, "input-vocal.wav")
	vocalPrepared := true
	if err := extractMonoWAV(sanitised.SongPath, vocalWavPath, defaultVocalFocusFilter); err != nil {
		logAutoSync("ボーカル重視前処理の抽出に失敗したため通常音声へフォールバック: %v", err)
		vocalPrepared = false
	}

	lineTargetCount := countTargetLyricLines(sanitised.Lines)
	type candidateSource struct {
		name       string
		wavPath    string
		allowEarly bool
	}

	sources := make([]candidateSource, 0, 3)
	if vocalMLPrepared {
		sources = append(sources, candidateSource{
			name:       "vocal-ml",
			wavPath:    vocalMLWavPath,
			allowEarly: true,
		})
	}
	if vocalPrepared {
		sources = append(sources, candidateSource{
			name:       "vocal-focus",
			wavPath:    vocalWavPath,
			allowEarly: true,
		})
	}
	sources = append(sources, candidateSource{
		name:       "plain",
		wavPath:    plainWavPath,
		allowEarly: false,
	})

	best := alignmentCandidate{}
	bestSet := false
	errors := make([]string, 0, len(sources))

	for _, source := range sources {
		candidateCtx, candidateCancel := context.WithTimeout(context.Background(), whisperTimeout)
		candidate, runErr := s.runAlignmentCandidate(candidateCtx, source.wavPath, sanitised, source.name)
		candidateCancel()
		if runErr != nil {
			errors = append(errors, fmt.Sprintf("%s=%v", source.name, runErr))
			logAutoSync("%s候補の解析に失敗: %v", source.name, runErr)
			continue
		}

		if lineTargetCount > 0 {
			matchRatio := float64(candidate.matchedCount) / float64(lineTargetCount)
			logAutoSync("%s候補: matched=%d ratio=%.3f avg=%.3f", source.name, candidate.matchedCount, matchRatio, candidate.avgConfidence)
			if source.allowEarly && matchRatio >= minVocalMatchRatio {
				logAutoSync("同期完了: candidate=%s matched=%d total=%d", candidate.name, candidate.matchedCount, len(candidate.lines))
				return successResult(candidate)
			}
		} else {
			logAutoSync("%s候補: matched=%d avg=%.3f", source.name, candidate.matchedCount, candidate.avgConfidence)
		}

		if !bestSet || isBetterCandidate(candidate, best) {
			best = candidate
			bestSet = true
		}
	}

	if !bestSet {
		if len(errors) > 0 {
			return failResult(fmt.Errorf("候補解析がすべて失敗: %s", strings.Join(errors, " / ")))
		}
		return failResult(fmt.Errorf("同期候補が生成できませんでした"))
	}

	logAutoSync("同期完了: candidate=%s matched=%d total=%d", best.name, best.matchedCount, len(best.lines))
	return successResult(best)
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
		segments:      segments,
	}, nil
}

func toDetectedSegments(segments []whisperSegment) []DetectedSegment {
	if len(segments) == 0 {
		return nil
	}

	result := make([]DetectedSegment, 0, len(segments))
	for _, segment := range segments {
		result = append(result, DetectedSegment{
			Start: segment.Start,
			End:   segment.End,
			Text:  segment.Text,
		})
	}
	return result
}

func successResult(candidate alignmentCandidate) Result {
	return Result{
		Success:          true,
		Lines:            candidate.lines,
		MatchedCount:     candidate.matchedCount,
		DetectedBy:       candidate.name,
		DetectedSegments: toDetectedSegments(candidate.segments),
	}
}

func isBetterCandidate(a alignmentCandidate, b alignmentCandidate) bool {
	if a.matchedCount != b.matchedCount {
		return a.matchedCount > b.matchedCount
	}
	if math.Abs(a.avgConfidence-b.avgConfidence) > 0.0001 {
		return a.avgConfidence > b.avgConfidence
	}
	return candidatePriority(a.name) > candidatePriority(b.name)
}

func candidatePriority(name string) int {
	switch name {
	case "vocal-ml":
		return 3
	case "vocal-focus":
		return 2
	case "plain":
		return 1
	default:
		return 0
	}
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

func resolveFFprobePath() (string, error) {
	if strings.TrimSpace(config.FFprobePath) != "" {
		if _, err := os.Stat(config.FFprobePath); err == nil {
			return config.FFprobePath, nil
		}
	}
	path, err := exec.LookPath("ffprobe")
	if err != nil {
		return "", fmt.Errorf("ffprobe が見つかりません")
	}
	return path, nil
}

func probeAudioDuration(inputPath string) (float64, error) {
	ffprobePath, err := resolveFFprobePath()
	if err != nil {
		return 0, err
	}

	args := []string{
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1",
		inputPath,
	}
	cmd := exec.Command(ffprobePath, args...)
	output, runErr := cmd.CombinedOutput()
	if runErr != nil {
		return 0, fmt.Errorf("ffprobe 実行に失敗しました: %v (%s)", runErr, strings.TrimSpace(string(output)))
	}

	trimmed := strings.TrimSpace(string(output))
	if trimmed == "" {
		return 0, fmt.Errorf("ffprobe の出力が空です")
	}
	duration, parseErr := strconv.ParseFloat(trimmed, 64)
	if parseErr != nil {
		return 0, fmt.Errorf("ffprobe 出力の解析に失敗しました: %w", parseErr)
	}
	if duration <= 0 {
		return 0, fmt.Errorf("音声長が0以下です: %f", duration)
	}
	return duration, nil
}

func computeWhisperTimeout(durationSeconds float64) time.Duration {
	if durationSeconds <= 0 {
		return defaultWhisperTimeout
	}

	computed := time.Duration((durationSeconds*1.6)+90.0) * time.Second
	if computed < minWhisperTimeout {
		return minWhisperTimeout
	}
	if computed > maxWhisperTimeout {
		return maxWhisperTimeout
	}
	return computed
}

func computeVocalMLTimeout(durationSeconds float64) time.Duration {
	if durationSeconds <= 0 {
		return defaultVocalMLTimeout
	}

	computed := time.Duration((durationSeconds*2.2)+120.0) * time.Second
	if computed < minVocalMLTimeout {
		return minVocalMLTimeout
	}
	if computed > maxVocalMLTimeout {
		return maxVocalMLTimeout
	}
	return computed
}

func logAutoSync(format string, args ...interface{}) {
	fmt.Printf("[Lyrics AutoSync] "+format+"\n", args...)
}
