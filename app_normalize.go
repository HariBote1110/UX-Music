package main

import (
	"runtime"
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

func (a *App) NormalizeStartJob(jobType string, files []interface{}, options normalize.OutputSettings) {
	var jobs []normalize.NormalizeJob
	for _, f := range files {
		fMap := f.(map[string]interface{})
		id, _ := fMap["id"].(string)
		path, _ := fMap["path"].(string)
		gain, _ := fMap["gain"].(float64)

		jobs = append(jobs, normalize.NormalizeJob{
			ID:       id,
			FilePath: path,
			Gain:     gain,
			Backup:   options.Mode == "overwrite",
			Output:   options,
			BasePath: "",
		})
	}

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
				} else {
					res = a.normalizer.ApplyNormalization(j)
				}

				wailsRuntime.EventsEmit(a.ctx, "normalize-worker-result", map[string]interface{}{
					"type":   jobType + "-result",
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
