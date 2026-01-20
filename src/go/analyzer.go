package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
)

// FFmpegPath stores the paths which should be Set via `init` message
var FFmpegPath string
var FFprobePath string

// AnalyzerConfig stores config for audio analysis
type AnalyzerConfig struct {
	FFmpegPath  string
	FFprobePath string
}

func SetAnalyzerPaths(ffmpeg, ffprobe string) {
	FFmpegPath = ffmpeg
	FFprobePath = ffprobe
}

type AnalysisResult struct {
	Path     string   `json:"path"`
	Loudness *float64 `json:"loudness,omitempty"`
	BPM      *int     `json:"bpm,omitempty"`
	Energy   *int     `json:"energy,omitempty"`
}

func AnalyzeSong(path string) (*AnalysisResult, error) {
	if FFmpegPath == "" {
		return nil, fmt.Errorf("ffmpeg path not set")
	}

	res := &AnalysisResult{Path: path}

	// 1. Loudness Analysis (volumedetect)
	// Wailsへの移行を見据えて、ffmpegの標準出力をシンプルに解析
	loudness, err := analyzeLoudness(path)
	if err == nil {
		res.Loudness = &loudness
	}

	// 2. BPM Analysis (using ffmpeg audio filter or external tool if available)
	// 簡易的に ffmpeg の bpm フィルタを使用 (精度は music-tempo より劣る可能性があるが、外部依存なし)
	// cmd: ffmpeg -i input.mp3 -af "afade=t=out:st=duration-3:d=3, asendcmd=0.0 affine fade out, abpm" -f null -
	// 今回は複雑さを避けるため、実装をスキップし、将来的に aubio 等の統合を検討

	// 3. Energy Analysis (Dynamics: Peak - RMS)
	energy, err := analyzeEnergy(path)
	if err == nil {
		res.Energy = &energy
	}

	return res, nil
}

func analyzeLoudness(path string) (float64, error) {
	cmd := exec.Command(FFmpegPath, "-i", path, "-af", "volumedetect", "-f", "null", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr // ffmpeg logs to stderr

	if err := cmd.Run(); err != nil {
		return 0, err
	}

	output := stderr.String()
	// [Parsed_volumedetect_0 @ ...] mean_volume: -15.4 dB
	re := regexp.MustCompile(`mean_volume:\s*(-?\d+\.\d+)\s*dB`)
	matches := re.FindStringSubmatch(output)
	if len(matches) > 1 {
		val, err := strconv.ParseFloat(matches[1], 64)
		if err != nil {
			return 0, err
		}
		return val, nil
	}
	return 0, fmt.Errorf("mean_volume not found")
}

func analyzeEnergy(path string) (int, error) {
	// astats filter gives Peak level and RMS level
	cmd := exec.Command(FFmpegPath, "-i", path, "-af", "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", "-f", "null", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return 0, err
	}

	output := stderr.String()

	// Parse Peak and RMS
	peakRe := regexp.MustCompile(`Peak level dB:\s*(-?\d+\.\d+)`)
	rmsRe := regexp.MustCompile(`RMS level dB:\s*(-?\d+\.\d+)`)

	peakMatches := peakRe.FindStringSubmatch(output)
	rmsMatches := rmsRe.FindStringSubmatch(output)

	if len(peakMatches) > 1 && len(rmsMatches) > 1 {
		peak, _ := strconv.ParseFloat(peakMatches[1], 64)
		rms, _ := strconv.ParseFloat(rmsMatches[1], 64)

		crestFactor := peak - rms
		// 0-10 scale
		score := int((crestFactor / 20.0) * 10)
		if score > 10 {
			score = 10
		}
		if score < 0 {
			score = 0
		}
		return score, nil
	}

	return 0, fmt.Errorf("stats not found")
}

// Helper to batch analyze
func BatchAnalyze(paths []string) []AnalysisResult {
	results := make([]AnalysisResult, len(paths))
	for i, p := range paths {
		res, err := AnalyzeSong(p)
		if err == nil {
			results[i] = *res
		} else {
			results[i] = AnalysisResult{Path: p} // Empty result on error
		}
	}
	return results
}
