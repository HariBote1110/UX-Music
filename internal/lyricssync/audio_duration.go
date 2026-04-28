package lyricssync

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"ux-music-sidecar/internal/config"
)

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
		return 0, fmt.Errorf("ffprobe: %w (%s)", runErr, strings.TrimSpace(string(output)))
	}

	trimmed := strings.TrimSpace(string(output))
	if trimmed == "" {
		return 0, fmt.Errorf("ffprobe output empty")
	}
	duration, parseErr := strconv.ParseFloat(trimmed, 64)
	if parseErr != nil {
		return 0, fmt.Errorf("ffprobe parse: %w", parseErr)
	}
	if duration <= 0 {
		return 0, fmt.Errorf("non-positive duration: %f", duration)
	}
	return duration, nil
}

func resolveFFprobePath() (string, error) {
	if strings.TrimSpace(config.FFprobePath) != "" {
		if _, err := os.Stat(config.FFprobePath); err == nil {
			return config.FFprobePath, nil
		}
	}
	path, err := exec.LookPath("ffprobe")
	if err != nil {
		return "", fmt.Errorf("ffprobe not found")
	}
	return path, nil
}
