package config

import "sync"

type AppConfig struct {
	UserDataPath string
	FFmpegPath   string
	FFprobePath  string
	mu           sync.RWMutex
}

var Instance = AppConfig{}

var (
	FFmpegPath  string
	FFprobePath string
)

func (c *AppConfig) SetUserDataPath(path string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.UserDataPath = path
}

func (c *AppConfig) GetUserDataPath() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.UserDataPath
}

func (c *AppConfig) SetFFmpegPaths(ffmpeg, ffprobe string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.FFmpegPath = ffmpeg
	c.FFprobePath = ffprobe
	FFmpegPath = ffmpeg
	FFprobePath = ffprobe
}

func SetUserDataPath(path string) {
	Instance.SetUserDataPath(path)
}

func GetUserDataPath() string {
	return Instance.GetUserDataPath()
}

func SetFFmpegPaths(ffmpeg, ffprobe string) {
	Instance.SetFFmpegPaths(ffmpeg, ffprobe)
}
