package main

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
)

func (a *App) NormalizeAnalyze(path string) normalize.AnalysisResult {
	return a.normalizer.AnalyzeLoudness(path)
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
		fMap, ok := f.(map[string]interface{})
		if !ok {
			continue
		}
		id, _ := fMap["id"].(string)
		path, _ := fMap["path"].(string)
		gain, _ := fMap["gain"].(float64)
		if path == "" {
			continue
		}

		backup := parsedOptions.Backup
		if jobBackup, ok := fMap["backup"].(bool); ok {
			backup = jobBackup
		}

		basePath := parsedOptions.BasePath
		if jobBasePath, ok := fMap["basePath"].(string); ok && jobBasePath != "" {
			basePath = jobBasePath
		}

		jobs = append(jobs, normalize.NormalizeJob{
			ID:       id,
			FilePath: path,
			Gain:     gain,
			Backup:   backup,
			Output:   parsedOptions.Output,
			BasePath: basePath,
		})
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
					res = a.normalizer.AnalyzeLoudness(j.FilePath)
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
	data, _ := store.Instance.Load("loudness")
	if data == nil {
		return nil, nil
	}
	loudnessMap := data.(map[string]interface{})
	return loudnessMap[path], nil
}

func (a *App) GetAllLoudnessData() (map[string]interface{}, error) {
	data, _ := store.Instance.Load("loudness")
	if data == nil {
		return map[string]interface{}{}, nil
	}
	if loudnessMap, ok := data.(map[string]interface{}); ok {
		return loudnessMap, nil
	}
	return map[string]interface{}{}, nil
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
