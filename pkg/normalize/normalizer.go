package normalize

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

// Normalizer manages normalization tasks
type Normalizer struct {
	FFmpegPath  string
	FFprobePath string
}

var resolvedCommandPaths sync.Map

// NewNormalizer creates a new Normalizer
func NewNormalizer(ffmpegPath, ffprobePath string) *Normalizer {
	return &Normalizer{
		FFmpegPath:  ffmpegPath,
		FFprobePath: ffprobePath,
	}
}

func isExecutablePath(path string) bool {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return false
	}
	info, err := os.Stat(trimmed)
	if err != nil || info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

func commandBinaryName(name string) string {
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(name), ".exe") {
		return name + ".exe"
	}
	return name
}

func buildCommandFallbackCandidates(name string) []string {
	binaryName := commandBinaryName(name)
	candidates := make([]string, 0, 8)

	executablePath, err := os.Executable()
	if err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(candidates,
			filepath.Clean(filepath.Join(executableDir, "..", "Resources", "bin", binaryName)),
			filepath.Clean(filepath.Join(executableDir, "..", "Resources", binaryName)),
		)
	}

	candidates = append(candidates,
		filepath.Join("/opt/homebrew/bin", binaryName),
		filepath.Join("/usr/local/bin", binaryName),
		filepath.Join("/opt/local/bin", binaryName),
		filepath.Join("/usr/bin", binaryName),
		filepath.Join("/bin", binaryName),
	)

	return candidates
}

func (n *Normalizer) resolveCommandPath(name string) (string, error) {
	if cachedPath, ok := resolvedCommandPaths.Load(name); ok {
		if path, ok := cachedPath.(string); ok && isExecutablePath(path) {
			return path, nil
		}
		resolvedCommandPaths.Delete(name)
	}

	if name == "ffmpeg" && isExecutablePath(n.FFmpegPath) {
		resolvedCommandPaths.Store(name, n.FFmpegPath)
		return n.FFmpegPath, nil
	}
	if name == "ffprobe" && isExecutablePath(n.FFprobePath) {
		resolvedCommandPaths.Store(name, n.FFprobePath)
		return n.FFprobePath, nil
	}

	path, err := exec.LookPath(name)
	if err == nil && isExecutablePath(path) {
		resolvedCommandPaths.Store(name, path)
		return path, nil
	}

	for _, candidate := range buildCommandFallbackCandidates(name) {
		if !isExecutablePath(candidate) {
			continue
		}
		resolvedCommandPaths.Store(name, candidate)
		fmt.Printf("[Normalize] command fallback resolved: %s -> %s\n", name, candidate)
		return candidate, nil
	}

	return "", fmt.Errorf("%s が見つかりません (PATH=%q)", name, os.Getenv("PATH"))
}

// AnalyzeLoudness runs volumedetect filter
func (n *Normalizer) AnalyzeLoudness(filePath string) AnalysisResult {
	ffmpegPath, err := n.resolveCommandPath("ffmpeg")
	if err != nil {
		return AnalysisResult{Success: false, Error: err.Error()}
	}

	cmd := exec.Command(ffmpegPath, "-i", filePath, "-af", "volumedetect", "-f", "null", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return AnalysisResult{Success: false, Error: err.Error()}
	}

	output := stderr.String()
	meanRe := regexp.MustCompile(`mean_volume:\s*(-?\d+\.\d+)\s*dB`)
	maxRe := regexp.MustCompile(`max_volume:\s*(-?\d+\.\d+)\s*dB`)

	meanMatch := meanRe.FindStringSubmatch(output)
	maxMatch := maxRe.FindStringSubmatch(output)

	if len(meanMatch) > 1 && len(maxMatch) > 1 {
		mean, _ := strconv.ParseFloat(meanMatch[1], 64)
		max, _ := strconv.ParseFloat(maxMatch[1], 64)
		return AnalysisResult{
			Success:  true,
			Loudness: mean,
			TruePeak: max,
		}
	}

	return AnalysisResult{Success: false, Error: "Could not find mean_volume or max_volume"}
}

// ApplyNormalization applies volume gain
func (n *Normalizer) ApplyNormalization(job NormalizeJob) NormalizeResult {
	ffmpegPath, err := n.resolveCommandPath("ffmpeg")
	if err != nil {
		return NormalizeResult{Success: false, Error: err.Error()}
	}

	isOverwrite := job.Output.Mode == "overwrite"
	originalExt := strings.ToLower(filepath.Ext(job.FilePath))

	// Conversion logic from JS
	shouldConvertToFlac := !isOverwrite && (originalExt == ".mp4" || originalExt == ".m4a")
	outputExt := originalExt
	if shouldConvertToFlac {
		outputExt = ".flac"
	}

	baseName := strings.TrimSuffix(filepath.Base(job.FilePath), originalExt)
	newFileName := baseName + outputExt

	var outputPath string
	if isOverwrite {
		outputPath = job.FilePath
	} else {
		relativeDir := ""
		if job.BasePath != "" && strings.HasPrefix(job.FilePath, job.BasePath) {
			rel, err := filepath.Rel(job.BasePath, job.FilePath)
			if err == nil {
				relativeDir = filepath.Dir(rel)
			}
		}
		outputPath = filepath.Join(job.Output.Path, relativeDir, newFileName)
	}

	tempPath := outputPath + ".tmp" + outputExt

	// Ensure dir
	if err := os.MkdirAll(filepath.Dir(outputPath), 0755); err != nil {
		return NormalizeResult{Success: false, Error: err.Error()}
	}

	// Backup
	if isOverwrite && job.Backup {
		backupPath := job.FilePath + ".bak"
		if _, err := os.Stat(backupPath); os.IsNotExist(err) {
			if err := copyFile(job.FilePath, backupPath); err != nil {
				return NormalizeResult{Success: false, Error: "Backup failed: " + err.Error()}
			}
		}
	}

	// Build FFmpeg command
	var args []string
	args = append(args, "-i", job.FilePath)
	args = append(args, "-af", fmt.Sprintf("volume=%.2fdB", job.Gain))

	// Codec settings
	switch outputExt {
	case ".flac":
		args = append(args, "-c:a", "flac")
		if originalExt == ".mp4" || originalExt == ".m4a" {
			// Copy video (artwork) if present
			args = append(args, "-c:v", "copy", "-map", "0:v?", "-map", "0:a")
		}
	case ".wav":
		args = append(args, "-c:a", "pcm_s16le")
	case ".m4a", ".mp4":
		args = append(args, "-c:a", "aac", "-b:a", "256k", "-vn")
	case ".mp3":
		args = append(args, "-c:a", "libmp3lame", "-q:a", "2", "-vn")
	}

	args = append(args, "-y", tempPath)

	cmd := exec.Command(ffmpegPath, args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		os.Remove(tempPath)
		return NormalizeResult{Success: false, Error: fmt.Sprintf("FFmpeg error: %s (%v)", string(output), err)}
	}

	// Finalize
	if err := os.Rename(tempPath, outputPath); err != nil {
		os.Remove(tempPath)
		return NormalizeResult{Success: false, Error: "Finalize failed: " + err.Error()}
	}

	return NormalizeResult{Success: true, OutputPath: outputPath}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}
