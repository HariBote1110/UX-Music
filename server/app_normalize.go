package server

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/normalize"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/text/unicode/norm"
)

func (a *App) NormalizeAnalyze(path string) normalize.AnalysisResult {
	result := a.normalizer.AnalyzeLoudness(path)
	if result.Success {
		a.saveLoudnessValue(path, result.Loudness)
	}
	return result
}

func (a *App) NormalizeApply(job normalize.NormalizeJob) normalize.NormalizeResult {
	return a.normalizer.ApplyNormalization(job)
}

type normalizeStartOptions struct {
	Backup   bool
	BasePath string
	Output   normalize.OutputSettings
}

func parseNormalizeStartOptions(raw interface{}) normalizeStartOptions {
	opts := normalizeStartOptions{
		Backup: false,
		Output: normalize.OutputSettings{
			Mode: "overwrite",
			Path: "",
		},
	}

	switch v := raw.(type) {
	case normalize.OutputSettings:
		if v.Mode != "" {
			opts.Output.Mode = v.Mode
		}
		opts.Output.Path = v.Path
	case map[string]interface{}:
		if mode, ok := v["mode"].(string); ok && mode != "" {
			opts.Output.Mode = mode
		}
		if path, ok := v["path"].(string); ok {
			opts.Output.Path = path
		}
		if outputRaw, ok := v["output"].(map[string]interface{}); ok {
			if mode, ok := outputRaw["mode"].(string); ok && mode != "" {
				opts.Output.Mode = mode
			}
			if path, ok := outputRaw["path"].(string); ok {
				opts.Output.Path = path
			}
		}
		if backup, ok := v["backup"].(bool); ok {
			opts.Backup = backup
		}
		if basePath, ok := v["basePath"].(string); ok {
			opts.BasePath = basePath
		}
	}

	if opts.Output.Mode == "" {
		opts.Output.Mode = "overwrite"
	}
	return opts
}

func normalizeResultEventType(jobType string) string {
	switch jobType {
	case "analyze":
		return "analysis-result"
	case "normalize":
		return "normalize-result"
	default:
		return jobType + "-result"
	}
}

func (a *App) NormalizeStartJob(jobType string, files []interface{}, options interface{}) {
	parsedOptions := parseNormalizeStartOptions(options)
	var jobs []normalize.NormalizeJob
	for _, f := range files {
		job, ok := normaliseJobFromPayload(f, parsedOptions)
		if !ok {
			continue
		}
		jobs = append(jobs, job)
	}

	if len(jobs) == 0 {
		wailsRuntime.EventsEmit(a.ctx, "normalize-job-finished")
		return
	}

	eventType := normalizeResultEventType(jobType)

	go func() {
		concurrency := runtime.GOMAXPROCS(0) - 1
		if concurrency < 1 {
			concurrency = 1
		}

		sem := make(chan struct{}, concurrency)
		var wg sync.WaitGroup

		for _, job := range jobs {
			wg.Add(1)
			sem <- struct{}{}
			go func(j normalize.NormalizeJob) {
				defer wg.Done()
				defer func() { <-sem }()

				var res interface{}
				if jobType == "analyze" {
					analyzeResult := a.normalizer.AnalyzeLoudness(j.FilePath)
					if analyzeResult.Success {
						a.saveLoudnessValue(j.FilePath, analyzeResult.Loudness)
					}
					res = analyzeResult
				} else if jobType == "normalize" {
					res = a.normalizer.ApplyNormalization(j)
				} else {
					res = normalize.NormalizeResult{Success: false, Error: fmt.Sprintf("unknown normalise job type: %s", jobType)}
				}

				wailsRuntime.EventsEmit(a.ctx, "normalize-worker-result", map[string]interface{}{
					"type":   eventType,
					"id":     j.ID,
					"result": res,
				})
			}(job)
		}
		wg.Wait()
		wailsRuntime.EventsEmit(a.ctx, "normalize-job-finished")
	}()
}

// GetLoudnessValue returns the saved loudness for a song
func (a *App) GetLoudnessValue(path string) (interface{}, error) {
	loudnessMap := loadLoudnessMap()
	for _, key := range loudnessPathCandidates(path) {
		if value, ok := loudnessMap[key]; ok {
			return value, nil
		}
	}
	return nil, nil
}

func (a *App) GetAllLoudnessData() (map[string]interface{}, error) {
	return loadLoudnessMap(), nil
}

func (a *App) GetLibraryForNormalize() ([]interface{}, error) {
	data, _ := store.Instance.Load("library")
	if data == nil {
		return []interface{}{}, nil
	}
	if songs, ok := data.([]interface{}); ok {
		return songs, nil
	}
	return []interface{}{}, nil
}

func (a *App) SelectFilesForNormalize() ([]string, error) {
	paths, err := wailsRuntime.OpenMultipleFilesDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "音声ファイルを選択",
		Filters: []wailsRuntime.FileFilter{
			{DisplayName: "Audio Files (*.mp3;*.flac;*.wav;*.m4a;*.ogg)", Pattern: "*.mp3;*.flac;*.wav;*.m4a;*.ogg"},
		},
	})
	if err != nil {
		return []string{}, err
	}
	return paths, nil
}

func (a *App) SelectNormalizeOutputFolder() (string, error) {
	path, err := wailsRuntime.OpenDirectoryDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "出力先フォルダを選択",
	})
	if err != nil {
		return "", err
	}
	return path, nil
}

func (a *App) SelectFolderForNormalize() ([]string, error) {
	root, err := wailsRuntime.OpenDirectoryDialog(a.ctx, wailsRuntime.OpenDialogOptions{
		Title: "フォルダを選択",
	})
	if err != nil {
		return []string{}, err
	}
	if root == "" {
		return []string{}, nil
	}

	supported := map[string]bool{
		".mp3":  true,
		".flac": true,
		".wav":  true,
		".m4a":  true,
		".ogg":  true,
	}

	var files []string
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			if d != nil && d.IsDir() {
				fmt.Printf("[Normalize] Skipping directory %s: %v\n", path, walkErr)
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}

		if supported[strings.ToLower(filepath.Ext(name))] {
			files = append(files, path)
		}
		return nil
	})

	sort.Strings(files)
	return files, nil
}

func loadLoudnessMap() map[string]interface{} {
	data, _ := store.Instance.Load("loudness")
	if loudnessMap, ok := data.(map[string]interface{}); ok {
		return loudnessMap
	}
	return map[string]interface{}{}
}

func hasNumericLoudnessValue(value interface{}) bool {
	switch value.(type) {
	case float64, float32, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return true
	default:
		return false
	}
}

func loudnessPathCandidates(path string) []string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return nil
	}

	cleaned := filepath.Clean(trimmed)
	nfc := norm.NFC.String(cleaned)
	nfd := norm.NFD.String(cleaned)

	candidates := make([]string, 0, 4)
	seen := make(map[string]struct{}, 4)
	for _, candidate := range []string{trimmed, cleaned, nfc, nfd} {
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		candidates = append(candidates, candidate)
	}
	return candidates
}

func hasStoredNumericLoudness(existing map[string]interface{}, path string) bool {
	for _, key := range loudnessPathCandidates(path) {
		if hasNumericLoudnessValue(existing[key]) {
			return true
		}
	}
	return false
}

func filterPendingLoudnessPaths(paths []string, existing map[string]interface{}) []string {
	if len(paths) == 0 {
		return nil
	}

	pending := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	for _, p := range paths {
		path := strings.TrimSpace(p)
		if path == "" {
			continue
		}
		if _, duplicated := seen[path]; duplicated {
			continue
		}
		seen[path] = struct{}{}
		if hasStoredNumericLoudness(existing, path) {
			continue
		}
		pending = append(pending, path)
	}
	return pending
}

func (a *App) queueLoudnessAnalysis(paths []string) {
	if a == nil || a.normalizer == nil {
		return
	}

	existing := loadLoudnessMap()
	pending := filterPendingLoudnessPaths(paths, existing)
	if len(pending) == 0 {
		return
	}

	go func(targets []string) {
		concurrency := runtime.GOMAXPROCS(0) - 1
		if concurrency < 1 {
			concurrency = 1
		}
		if concurrency > 4 {
			concurrency = 4
		}

		sem := make(chan struct{}, concurrency)
		var wg sync.WaitGroup

		for _, path := range targets {
			filePath := path

			wg.Add(1)
			sem <- struct{}{}
			go func() {
				defer wg.Done()
				defer func() { <-sem }()

				result := a.normalizer.AnalyzeLoudness(filePath)
				if result.Success {
					a.saveLoudnessValue(filePath, result.Loudness)
				}

				if a.ctx != nil {
					wailsRuntime.EventsEmit(a.ctx, "loudness-analysis-result", map[string]interface{}{
						"success":  result.Success,
						"loudness": result.Loudness,
						"truePeak": result.TruePeak,
						"error":    result.Error,
						"filePath": filePath,
					})
				}
			}()
		}

		wg.Wait()
	}(pending)
}

func (a *App) saveLoudnessValue(path string, loudness float64) {
	candidates := loudnessPathCandidates(path)
	if len(candidates) == 0 {
		return
	}

	a.loudnessMu.Lock()
	defer a.loudnessMu.Unlock()

	loudnessMap := loadLoudnessMap()
	for _, key := range candidates {
		loudnessMap[key] = loudness
	}
	if err := store.Instance.Save("loudness", loudnessMap); err != nil {
		fmt.Printf("[Normalize] Failed to save loudness for %s: %v\n", path, err)
	}
}
