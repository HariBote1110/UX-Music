package youtube

import (
	"context"
	"fmt"
	"html"
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
	Lyrics    string `json:"lyrics,omitempty"`
	Lang      string `json:"lang,omitempty"`
}

var hubURLRegex = regexp.MustCompile(`https?://(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)/[\w\-/.?=&#]+`)

func findHubURL(description string) string {
	match := hubURLRegex.FindString(description)
	return match
}

type captionTrackMatch struct {
	Track    youtube.CaptionTrack
	Priority int
}

func isAutoCaption(track youtube.CaptionTrack) bool {
	return strings.EqualFold(strings.TrimSpace(track.Kind), "asr")
}

func languagePriority(lang string) int {
	lower := strings.ToLower(strings.TrimSpace(lang))
	switch {
	case strings.HasPrefix(lower, "ja"):
		return 0
	case strings.HasPrefix(lower, "en"):
		return 1
	default:
		return 2
	}
}

func buildCaptionTrackCandidates(tracks []youtube.CaptionTrack) []captionTrackMatch {
	candidates := make([]captionTrackMatch, 0, len(tracks))
	for _, track := range tracks {
		base := languagePriority(track.LanguageCode) * 10
		if isAutoCaption(track) {
			base += 100
		}
		candidates = append(candidates, captionTrackMatch{
			Track:    track,
			Priority: base,
		})
	}

	for i := 0; i < len(candidates)-1; i++ {
		for j := i + 1; j < len(candidates); j++ {
			if candidates[i].Priority > candidates[j].Priority {
				candidates[i], candidates[j] = candidates[j], candidates[i]
			}
		}
	}
	return candidates
}

func sanitiseTranscriptText(text string) string {
	unescaped := html.UnescapeString(text)
	fields := strings.Fields(strings.ReplaceAll(unescaped, "\n", " "))
	return strings.TrimSpace(strings.Join(fields, " "))
}

func formatLRCFromMilliseconds(ms int) string {
	if ms < 0 {
		ms = 0
	}
	minutes := ms / 60000
	seconds := (ms % 60000) / 1000
	centiseconds := (ms % 1000) / 10
	return fmt.Sprintf("%02d:%02d.%02d", minutes, seconds, centiseconds)
}

func transcriptToLRC(video *youtube.Video, transcript youtube.VideoTranscript) string {
	lines := make([]string, 0, len(transcript)+2)
	lyricLineCount := 0

	title := strings.TrimSpace(video.Title)
	if title != "" {
		lines = append(lines, fmt.Sprintf("[ti:%s]", title))
	}

	author := strings.TrimSpace(video.Author)
	if author != "" {
		lines = append(lines, fmt.Sprintf("[ar:%s]", author))
	}

	for _, segment := range transcript {
		text := sanitiseTranscriptText(segment.Text)
		if text == "" {
			continue
		}
		lines = append(lines, fmt.Sprintf("[%s]%s", formatLRCFromMilliseconds(segment.StartMs), text))
		lyricLineCount++
	}

	if lyricLineCount == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

func downloadTranscriptAsLRC(client *youtube.Client, video *youtube.Video) (string, string) {
	if video == nil || len(video.CaptionTracks) == 0 {
		return "", ""
	}

	candidates := buildCaptionTrackCandidates(video.CaptionTracks)
	visited := make(map[string]bool, len(candidates))

	for _, candidate := range candidates {
		lang := strings.TrimSpace(candidate.Track.LanguageCode)
		if lang == "" || visited[lang] {
			continue
		}
		visited[lang] = true

		transcript, err := client.GetTranscript(video, lang)
		if err != nil || len(transcript) == 0 {
			continue
		}

		lrc := transcriptToLRC(video, transcript)
		if strings.TrimSpace(lrc) == "" {
			continue
		}
		return lrc, lang
	}

	return "", ""
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

	lyrics, lang := downloadTranscriptAsLRC(&client, video)

	return &YouTubeDownloadResult{
		Path:      destPath,
		Title:     video.Title,
		Artist:    video.Author,
		Duration:  int(video.Duration.Seconds()),
		FileSize:  fileSize,
		Thumbnail: thumbnail,
		HubURL:    findHubURL(video.Description),
		Lyrics:    lyrics,
		Lang:      lang,
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
