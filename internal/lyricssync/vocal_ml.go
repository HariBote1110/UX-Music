package lyricssync

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	envVocalSeparatorPath = "UXMUSIC_LYRICS_SYNC_VOCAL_SEPARATOR"
	envDemucsPath         = "UXMUSIC_LYRICS_SYNC_DEMUCS"
	envDemucsModel        = "UXMUSIC_LYRICS_SYNC_DEMUCS_MODEL"
	defaultDemucsModel    = "mdx_extra"
)

func extractVocalWithML(ctx context.Context, inputPath string, workDir string, outputWavPath string) error {
	customSeparator := strings.TrimSpace(os.Getenv(envVocalSeparatorPath))
	if customSeparator != "" {
		return runCustomVocalSeparator(ctx, customSeparator, inputPath, workDir, outputWavPath)
	}
	return runDemucsVocalSeparator(ctx, inputPath, workDir, outputWavPath)
}

func runCustomVocalSeparator(ctx context.Context, separatorPath string, inputPath string, workDir string, outputWavPath string) error {
	if _, err := os.Stat(separatorPath); err != nil {
		return fmt.Errorf("環境変数 %s の実行ファイルが見つかりません: %w", envVocalSeparatorPath, err)
	}

	rawOutputPath := filepath.Join(workDir, "vocal-ml-raw.wav")
	args := []string{inputPath, rawOutputPath}
	logAutoSync("MLボーカル抽出(カスタム)実行: %s %s", separatorPath, strings.Join(args, " "))

	cmd := exec.CommandContext(ctx, separatorPath, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("カスタムボーカル抽出に失敗しました: %v (%s)", err, strings.TrimSpace(string(output)))
	}

	if _, statErr := os.Stat(rawOutputPath); statErr != nil {
		return fmt.Errorf("カスタムボーカル抽出の出力が見つかりません: %w", statErr)
	}

	if convErr := extractMonoWAV(rawOutputPath, outputWavPath, ""); convErr != nil {
		return fmt.Errorf("カスタム抽出結果の変換に失敗しました: %w", convErr)
	}
	return nil
}

func runDemucsVocalSeparator(ctx context.Context, inputPath string, workDir string, outputWavPath string) error {
	demucsPath, err := resolveDemucsPath()
	if err != nil {
		return err
	}

	outDir := filepath.Join(workDir, "demucs-out")
	modelName := strings.TrimSpace(os.Getenv(envDemucsModel))
	if modelName == "" {
		modelName = defaultDemucsModel
	}
	modelCandidates := buildDemucsModelCandidates(modelName)
	errors := make([]string, 0, len(modelCandidates))

	for _, model := range modelCandidates {
		_ = os.RemoveAll(outDir)

		args := []string{
			"--name", model,
			"--jobs", "1",
			"--two-stems=vocals",
			"--out", outDir,
			inputPath,
		}
		logAutoSync("MLボーカル抽出(demucs)実行: %s %s", demucsPath, strings.Join(args, " "))

		cmd := exec.CommandContext(ctx, demucsPath, args...)
		output, runErr := cmd.CombinedOutput()
		if runErr != nil {
			message := strings.TrimSpace(string(output))
			errors = append(errors, fmt.Sprintf("%s: %v (%s)", model, runErr, message))
			if isDemucsDiffqError(message) {
				logAutoSync("demucsモデル %s は diffq 未導入のため利用不可。次候補へ切替します", model)
			}
			continue
		}

		vocalStemPath, findErr := findDemucsVocalStem(outDir)
		if findErr != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", model, findErr))
			continue
		}

		if convErr := extractMonoWAV(vocalStemPath, outputWavPath, ""); convErr != nil {
			errors = append(errors, fmt.Sprintf("%s: demucs 出力の変換に失敗しました: %v", model, convErr))
			continue
		}
		return nil
	}

	if len(errors) == 0 {
		return fmt.Errorf("demucs 実行に失敗しました")
	}
	return fmt.Errorf("demucs 実行に失敗しました: %s", strings.Join(errors, " / "))
}

func buildDemucsModelCandidates(primary string) []string {
	candidates := make([]string, 0, 3)
	seen := make(map[string]struct{})
	appendIfAbsent := func(name string) {
		norm := strings.TrimSpace(name)
		if norm == "" {
			return
		}
		if _, exists := seen[norm]; exists {
			return
		}
		seen[norm] = struct{}{}
		candidates = append(candidates, norm)
	}

	appendIfAbsent(primary)
	if strings.HasSuffix(primary, "_q") {
		appendIfAbsent(strings.TrimSuffix(primary, "_q"))
	}
	appendIfAbsent(defaultDemucsModel)
	return candidates
}

func isDemucsDiffqError(message string) bool {
	return strings.Contains(strings.ToLower(message), "diffq")
}

func resolveDemucsPath() (string, error) {
	if value := strings.TrimSpace(os.Getenv(envDemucsPath)); value != "" {
		if _, err := os.Stat(value); err == nil {
			return value, nil
		}
		return "", fmt.Errorf("環境変数 %s のパスが見つかりません: %s", envDemucsPath, value)
	}

	if path, err := exec.LookPath("demucs"); err == nil {
		return path, nil
	}

	candidates := []string{
		"/opt/homebrew/bin/demucs",
		"/usr/local/bin/demucs",
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("demucs が見つかりません。PATH または %s を設定してください", envDemucsPath)
}

func findDemucsVocalStem(outDir string) (string, error) {
	candidates := make([]string, 0, 4)
	walkErr := filepath.WalkDir(outDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		name := strings.ToLower(entry.Name())
		if name == "vocals.wav" || strings.HasPrefix(name, "vocals.") {
			candidates = append(candidates, path)
		}
		return nil
	})
	if walkErr != nil {
		return "", fmt.Errorf("demucs 出力の探索に失敗しました: %w", walkErr)
	}
	if len(candidates) == 0 {
		return "", fmt.Errorf("demucs の出力から vocals トラックが見つかりません")
	}

	sort.Strings(candidates)
	return candidates[0], nil
}
