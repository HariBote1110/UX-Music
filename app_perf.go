package main

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
	"ux-music-sidecar/internal/store"
)

type PerformanceSnapshot struct {
	TimestampUTC        string  `json:"timestampUtc"`
	ProcessRSSMB        float64 `json:"processRssMb"`
	ProcessCPUPercent   float64 `json:"processCpuPercent"`
	GoHeapAllocMB       float64 `json:"goHeapAllocMb"`
	GoSysMB             float64 `json:"goSysMb"`
	GoNumGoroutine      int     `json:"goNumGoroutine"`
	LibrarySongCount    int     `json:"librarySongCount"`
	PerformanceSourceOK bool    `json:"performanceSourceOk"`
}

func (a *App) GetPerformanceSnapshot() (PerformanceSnapshot, error) {
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	rssMB, cpuPercent, sourceOK := readCurrentProcessUsage()

	snapshot := PerformanceSnapshot{
		TimestampUTC:        time.Now().UTC().Format(time.RFC3339),
		ProcessRSSMB:        rssMB,
		ProcessCPUPercent:   cpuPercent,
		GoHeapAllocMB:       bytesToMB(memStats.HeapAlloc),
		GoSysMB:             bytesToMB(memStats.Sys),
		GoNumGoroutine:      runtime.NumGoroutine(),
		LibrarySongCount:    a.getLibrarySongCount(),
		PerformanceSourceOK: sourceOK,
	}

	return snapshot, nil
}

func (a *App) getLibrarySongCount() int {
	if a == nil {
		return 0
	}

	songs, err := store.Instance.Load("library")
	if err != nil {
		return 0
	}

	songList, ok := songs.([]interface{})
	if !ok {
		return 0
	}

	return len(songList)
}

func readCurrentProcessUsage() (float64, float64, bool) {
	pid := strconv.Itoa(os.Getpid())
	output, err := exec.Command("ps", "-o", "rss=", "-o", "%cpu=", "-p", pid).Output()
	if err != nil {
		return 0, 0, false
	}

	fields := strings.Fields(string(output))
	if len(fields) < 2 {
		return 0, 0, false
	}

	rssKB, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, false
	}

	cpuPercent, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return 0, 0, false
	}

	return rssKB / 1024, cpuPercent, true
}

func bytesToMB(value uint64) float64 {
	return float64(value) / 1024 / 1024
}
