package analyzer

import (
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"sync"
	"ux-music-sidecar/internal/config"
)

// FFmpegPath and FFprobePath are now in config package

var (
	meanVolumeRe = regexp.MustCompile(`mean_volume:\s*(-?\d+\.\d+)\s*dB`)
	peakRe       = regexp.MustCompile(`Peak level dB:\s*(-?\d+\.\d+)`)
	rmsRe        = regexp.MustCompile(`RMS level dB:\s*(-?\d+\.\d+)`)
)

type AnalysisResult struct {
	Path     string   `json:"path"`
	Loudness *float64 `json:"loudness,omitempty"`
	BPM      *int     `json:"bpm,omitempty"`
	Energy   *int     `json:"energy,omitempty"`
}

func AnalyzeSong(path string) (*AnalysisResult, error) {
	if config.FFmpegPath == "" {
		return nil, fmt.Errorf("ffmpeg path not set")
	}

	res := &AnalysisResult{Path: path}

	loudness, err := analyzeLoudness(path)
	if err == nil {
		res.Loudness = &loudness
	}

	energy, err := analyzeEnergy(path)
	if err == nil {
		res.Energy = &energy
	}

	return res, nil
}

func analyzeLoudness(path string) (float64, error) {
	cmd := exec.Command(config.FFmpegPath, "-i", path, "-af", "volumedetect", "-f", "null", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return 0, err
	}

	output := stderr.String()
	matches := meanVolumeRe.FindStringSubmatch(output)
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
	cmd := exec.Command(config.FFmpegPath, "-i", path, "-af", "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", "-f", "null", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return 0, err
	}

	output := stderr.String()

	peakMatches := peakRe.FindStringSubmatch(output)
	rmsMatches := rmsRe.FindStringSubmatch(output)

	if len(peakMatches) > 1 && len(rmsMatches) > 1 {
		peak, _ := strconv.ParseFloat(peakMatches[1], 64)
		rms, _ := strconv.ParseFloat(rmsMatches[1], 64)

		crestFactor := peak - rms
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

func BatchAnalyze(paths []string) []AnalysisResult {
	results := make([]AnalysisResult, len(paths))
	maxWorkers := 4
	sem := make(chan struct{}, maxWorkers)
	var wg sync.WaitGroup

	for i, p := range paths {
		wg.Add(1)
		go func(idx int, path string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			res, err := AnalyzeSong(path)
			if err == nil && res != nil {
				results[idx] = *res
			} else {
				results[idx] = AnalysisResult{Path: path}
			}
		}(i, p)
	}

	wg.Wait()
	return results
}
