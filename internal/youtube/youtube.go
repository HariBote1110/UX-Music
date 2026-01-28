package youtube

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/kkdai/youtube/v2"
)

// YouTubeVideoInfo represents information about a YouTube video
type YouTubeVideoInfo struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Author      string   `json:"author"`
	Duration    int      `json:"duration"`
	Thumbnail   string   `json:"thumbnail"`
	Description string   `json:"description"`
	HubURL      string   `json:"hubUrl,omitempty"`
	Formats     []Format `json:"formats"`
}

// Format represents an available video/audio format
type Format struct {
	ItagNo       int    `json:"itag"`
	Quality      string `json:"quality"`
	MimeType     string `json:"mimeType"`
	AudioQuality string `json:"audioQuality,omitempty"`
	HasVideo     bool   `json:"hasVideo"`
	HasAudio     bool   `json:"hasAudio"`
	Bitrate      int    `json:"bitrate"`
}

// YouTubeDownloadResult represents the result of a download
type YouTubeDownloadResult struct {
	Path      string `json:"path"`
	Title     string `json:"title"`
	Artist    string `json:"artist"`
	Duration  int    `json:"duration"`
	FileSize  int64  `json:"fileSize"`
	Thumbnail string `json:"thumbnail"`
	HubURL    string `json:"hubUrl,omitempty"`
}

var hubURLRegex = regexp.MustCompile(`https?://(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)/[\w\-/.?=&#]+`)

func findHubURL(description string) string {
	match := hubURLRegex.FindString(description)
	return match
}

// sanitizeFilename removes invalid characters from filename
func sanitizeFilename(name string) string {
	invalid := []string{"/", "\\", ":", "*", "?", "\"", "<", ">", "|"}
	result := name
	for _, char := range invalid {
		result = strings.ReplaceAll(result, char, "_")
	}
	result = strings.Trim(result, " .")
	if result == "" {
		result = "unknown"
	}
	return result
}

// GetYouTubeVideoInfo fetches video information without downloading
func GetYouTubeVideoInfo(url string) (*YouTubeVideoInfo, error) {
	client := youtube.Client{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	video, err := client.GetVideoContext(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("failed to get video info: %w", err)
	}

	thumbnail := ""
	if len(video.Thumbnails) > 0 {
		thumbnail = video.Thumbnails[len(video.Thumbnails)-1].URL
	}

	formats := make([]Format, 0)
	for _, f := range video.Formats {
		formats = append(formats, Format{
			ItagNo:       f.ItagNo,
			Quality:      f.Quality,
			MimeType:     f.MimeType,
			AudioQuality: f.AudioQuality,
			HasVideo:     f.QualityLabel != "",
			HasAudio:     f.AudioQuality != "",
			Bitrate:      f.Bitrate,
		})
	}

	return &YouTubeVideoInfo{
		ID:          video.ID,
		Title:       video.Title,
		Author:      video.Author,
		Duration:    int(video.Duration.Seconds()),
		Thumbnail:   thumbnail,
		Description: video.Description,
		HubURL:      findHubURL(video.Description),
		Formats:     formats,
	}, nil
}

// DownloadYouTubeVideo downloads a YouTube video to the specified directory
func DownloadYouTubeVideo(videoURL string, destDir string, audioOnly bool) (*YouTubeDownloadResult, error) {
	client := youtube.Client{}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	video, err := client.GetVideoContext(ctx, videoURL)
	if err != nil {
		return nil, fmt.Errorf("failed to get video: %w", err)
	}

	var format *youtube.Format
	var extension string

	if audioOnly {
		formats := video.Formats.WithAudioChannels()
		formats.Sort()
		for i := range formats {
			f := &formats[i]
			if strings.Contains(f.MimeType, "audio") {
				format = f
				break
			}
		}
		if format == nil && len(formats) > 0 {
			format = &formats[0]
		}
		extension = ".m4a"
	} else {
		formats := video.Formats.WithAudioChannels()
		formats.Sort()
		for i := range formats {
			f := &formats[i]
			if f.QualityLabel != "" && f.AudioQuality != "" {
				format = f
				break
			}
		}
		if format == nil && len(formats) > 0 {
			format = &formats[0]
		}
		extension = ".mp4"
	}

	if format == nil {
		return nil, fmt.Errorf("no suitable format found")
	}

	artistDir := filepath.Join(destDir, sanitizeFilename(video.Author))
	if err := os.MkdirAll(artistDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create directory: %w", err)
	}

	filename := sanitizeFilename(video.Title) + extension
	destPath := filepath.Join(artistDir, filename)

	stream, _, err := client.GetStreamContext(ctx, video, format)
	if err != nil {
		return nil, fmt.Errorf("failed to get stream: %w", err)
	}
	defer stream.Close()

	file, err := os.Create(destPath)
	if err != nil {
		return nil, fmt.Errorf("failed to create file: %w", err)
	}
	defer file.Close()

	_, err = io.Copy(file, stream)
	if err != nil {
		os.Remove(destPath)
		return nil, fmt.Errorf("failed to download: %w", err)
	}

	stat, _ := file.Stat()
	fileSize := int64(0)
	if stat != nil {
		fileSize = stat.Size()
	}

	thumbnail := ""
	if len(video.Thumbnails) > 0 {
		thumbnail = video.Thumbnails[len(video.Thumbnails)-1].URL
	}

	return &YouTubeDownloadResult{
		Path:      destPath,
		Title:     video.Title,
		Artist:    video.Author,
		Duration:  int(video.Duration.Seconds()),
		FileSize:  fileSize,
		Thumbnail: thumbnail,
		HubURL:    findHubURL(video.Description),
	}, nil
}

// DownloadThumbnail downloads a thumbnail image to the specified path
func DownloadThumbnail(thumbnailURL string, destPath string) error {
	resp, err := http.Get(thumbnailURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	file, err := os.Create(destPath)
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = io.Copy(file, resp.Body)
	return err
}

// GetYouTubeStreamURL returns a direct stream URL for the video
func GetYouTubeStreamURL(videoURL string) (string, error) {
	client := youtube.Client{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	video, err := client.GetVideoContext(ctx, videoURL)
	if err != nil {
		return "", fmt.Errorf("failed to get video: %w", err)
	}

	formats := video.Formats.WithAudioChannels()
	formats.Sort()

	if len(formats) == 0 {
		return "", fmt.Errorf("no formats available")
	}

	return formats[0].URL, nil
}
