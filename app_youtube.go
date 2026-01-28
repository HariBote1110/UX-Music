package main

import (
	"ux-music-sidecar/internal/youtube"
)

// GetYouTubeInfo calls the existing GetYouTubeVideoInfo logic
func (a *App) GetYouTubeInfo(url string) (interface{}, error) {
	return youtube.GetYouTubeVideoInfo(url)
}
