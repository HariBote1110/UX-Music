package youtube

import (
	"context"
	"encoding/xml"
	"fmt"
	"html"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/kkdai/youtube/v2"
)

// YouTubeVideoInfo represents information about a YouTube video
type YouTubeVideoInfo struct {
	ID            string             `json:"id"`
	Title         string             `json:"title"`
	Author        string             `json:"author"`
	Duration      int                `json:"duration"`
	Thumbnail     string             `json:"thumbnail"`
	Description   string             `json:"description"`
	HubURL        string             `json:"hubUrl,omitempty"`
	Formats       []Format           `json:"formats"`
	CaptionTracks []CaptionTrackInfo `json:"captionTracks,omitempty"`
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
	Path              string `json:"path"`
	Title             string `json:"title"`
	Artist            string `json:"artist"`
	Duration          int    `json:"duration"`
	FileSize          int64  `json:"fileSize"`
	Thumbnail         string `json:"thumbnail"`
	HubURL            string `json:"hubUrl,omitempty"`
	Lyrics            string `json:"lyrics,omitempty"`
	Lang              string `json:"lang,omitempty"`
	CaptionTrackVssID string `json:"captionTrackVssId,omitempty"`
}

type CaptionTrackInfo struct {
	Index        int    `json:"index"`
	VssID        string `json:"vssId,omitempty"`
	LanguageCode string `json:"languageCode"`
	Label        string `json:"label"`
	Kind         string `json:"kind,omitempty"`
	IsAuto       bool   `json:"isAuto"`
	Priority     int    `json:"priority"`
}

type TranscriptPreference struct {
	Mode         string `json:"mode,omitempty"`
	LanguageCode string `json:"languageCode,omitempty"`
	VssID        string `json:"vssId,omitempty"`
}

var hubURLRegex = regexp.MustCompile(`https?://(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)/[\w\-/.?=&#]+`)

func findHubURL(description string) string {
	match := hubURLRegex.FindString(description)
	return match
}

func normaliseTranscriptPreference(preference TranscriptPreference) TranscriptPreference {
	preference.Mode = strings.ToLower(strings.TrimSpace(preference.Mode))
	if preference.Mode == "" {
		preference.Mode = "auto"
	}
	preference.LanguageCode = strings.TrimSpace(preference.LanguageCode)
	preference.VssID = strings.TrimSpace(preference.VssID)
	return preference
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

func captionTrackLabel(track youtube.CaptionTrack) string {
	name := strings.TrimSpace(track.Name.SimpleText)
	if name == "" {
		name = strings.TrimSpace(track.LanguageCode)
	}
	if name == "" {
		name = "Unknown"
	}
	if isAutoCaption(track) {
		return name + " (Auto)"
	}
	return name
}

func buildCaptionTrackInfoList(tracks []youtube.CaptionTrack) []CaptionTrackInfo {
	candidates := buildCaptionTrackCandidates(tracks)
	infos := make([]CaptionTrackInfo, 0, len(candidates))
	for idx, candidate := range candidates {
		infos = append(infos, CaptionTrackInfo{
			Index:        idx,
			VssID:        strings.TrimSpace(candidate.Track.VssID),
			LanguageCode: strings.TrimSpace(candidate.Track.LanguageCode),
			Label:        captionTrackLabel(candidate.Track),
			Kind:         strings.TrimSpace(candidate.Track.Kind),
			IsAuto:       isAutoCaption(candidate.Track),
			Priority:     candidate.Priority,
		})
	}
	return infos
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

type transcriptXML struct {
	Entries []struct {
		Start string `xml:"start,attr"`
		Dur   string `xml:"dur,attr"`
		Text  string `xml:",chardata"`
	} `xml:"text"`
	Body struct {
		Entries []struct {
			Start string `xml:"t,attr"`
			Dur   string `xml:"d,attr"`
			Text  string `xml:",chardata"`
			Span  []struct {
				Text string `xml:",chardata"`
			} `xml:"s"`
		} `xml:"p"`
	} `xml:"body"`
}

func appendTranscriptSegment(result youtube.VideoTranscript, startMs int, durationMs int, rawText string) youtube.VideoTranscript {
	text := sanitiseTranscriptText(rawText)
	if text == "" {
		return result
	}

	return append(result, youtube.TranscriptSegment{
		Text:       text,
		StartMs:    startMs,
		OffsetText: formatLRCFromMilliseconds(startMs),
		Duration:   durationMs,
	})
}

func parseTranscriptXMLBody(body []byte) (youtube.VideoTranscript, string, error) {
	var parsed transcriptXML
	if err := xml.Unmarshal(body, &parsed); err != nil {
		return nil, "", err
	}

	result := make(youtube.VideoTranscript, 0, len(parsed.Entries)+len(parsed.Body.Entries))

	for _, entry := range parsed.Entries {
		startSeconds, err := strconv.ParseFloat(strings.TrimSpace(entry.Start), 64)
		if err != nil {
			continue
		}
		durationSeconds, _ := strconv.ParseFloat(strings.TrimSpace(entry.Dur), 64)
		startMs := int(math.Round(startSeconds * 1000))
		durationMs := int(math.Round(durationSeconds * 1000))
		result = appendTranscriptSegment(result, startMs, durationMs, entry.Text)
	}
	if len(result) > 0 {
		return result, "xml-text", nil
	}

	for _, entry := range parsed.Body.Entries {
		startMilliseconds, err := strconv.ParseFloat(strings.TrimSpace(entry.Start), 64)
		if err != nil {
			continue
		}
		durationMilliseconds, _ := strconv.ParseFloat(strings.TrimSpace(entry.Dur), 64)
		startMs := int(math.Round(startMilliseconds))
		durationMs := int(math.Round(durationMilliseconds))

		spanTexts := make([]string, 0, len(entry.Span))
		for _, span := range entry.Span {
			if strings.TrimSpace(span.Text) == "" {
				continue
			}
			spanTexts = append(spanTexts, span.Text)
		}

		joinedSpan := strings.TrimSpace(strings.Join(spanTexts, " "))
		if joinedSpan != "" {
			result = appendTranscriptSegment(result, startMs, durationMs, joinedSpan)
			continue
		}
		result = appendTranscriptSegment(result, startMs, durationMs, entry.Text)
	}

	if len(result) == 0 {
		return nil, "", fmt.Errorf("no transcript entry in track response")
	}
	return result, "xml-timedtext-body", nil
}

func loadTranscriptByTrack(ctx context.Context, track youtube.CaptionTrack) (youtube.VideoTranscript, error) {
	baseURL := strings.TrimSpace(track.BaseURL)
	if baseURL == "" {
		return nil, fmt.Errorf("caption track baseUrl is empty")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL, nil)
	if err != nil {
		return nil, err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("caption track request failed: status=%d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	contentType := strings.TrimSpace(resp.Header.Get("Content-Type"))
	fmt.Printf("[YouTube][Transcript] direct track response lang=%q vssId=%q status=%d contentType=%q bytes=%d\n",
		strings.TrimSpace(track.LanguageCode), strings.TrimSpace(track.VssID), resp.StatusCode, contentType, len(body))

	result, formatName, parseErr := parseTranscriptXMLBody(body)
	if parseErr != nil {
		snippet := strings.TrimSpace(string(body))
		if len(snippet) > 160 {
			snippet = snippet[:160]
		}
		return nil, fmt.Errorf("caption parse failed (lang=%q vssId=%q): %w snippet=%q",
			strings.TrimSpace(track.LanguageCode), strings.TrimSpace(track.VssID), parseErr, snippet)
	}

	fmt.Printf("[YouTube][Transcript] direct track parsed format=%s lang=%q vssId=%q segments=%d\n",
		formatName, strings.TrimSpace(track.LanguageCode), strings.TrimSpace(track.VssID), len(result))
	return result, nil
}

func downloadTranscriptAsLRC(client *youtube.Client, video *youtube.Video, preference TranscriptPreference) (string, string, string) {
	if video == nil || len(video.CaptionTracks) == 0 {
		fmt.Println("[YouTube][Transcript] caption track unavailable")
		return "", "", ""
	}

	preference = normaliseTranscriptPreference(preference)
	fmt.Printf("[YouTube][Transcript] mode=%s language=%q vssId=%q totalTracks=%d\n", preference.Mode, preference.LanguageCode, preference.VssID, len(video.CaptionTracks))

	if preference.Mode == "none" {
		fmt.Println("[YouTube][Transcript] skip transcript by user preference")
		return "", "", ""
	}

	candidates := buildCaptionTrackCandidates(video.CaptionTracks)

	if preference.VssID != "" {
		for _, candidate := range candidates {
			if strings.TrimSpace(candidate.Track.VssID) == preference.VssID {
				preference.LanguageCode = strings.TrimSpace(candidate.Track.LanguageCode)
				trackCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				transcript, trackErr := loadTranscriptByTrack(trackCtx, candidate.Track)
				cancel()
				if trackErr != nil {
					fmt.Printf("[YouTube][Transcript] direct track fetch failed vssId=%q err=%v; fallback to language route\n", preference.VssID, trackErr)
					break
				}

				lrc := transcriptToLRC(video, transcript)
				if strings.TrimSpace(lrc) != "" {
					fmt.Printf("[YouTube][Transcript] selected by direct track fetch lang=%q vssId=%q segments=%d\n",
						preference.LanguageCode, preference.VssID, len(transcript))
					return lrc, preference.LanguageCode, preference.VssID
				}
				fmt.Printf("[YouTube][Transcript] direct track fetch returned empty lrc vssId=%q; fallback to language route\n", preference.VssID)
				break
			}
		}
	}

	if preference.LanguageCode != "" {
		filtered := make([]captionTrackMatch, 0, len(candidates))
		for _, candidate := range candidates {
			if strings.EqualFold(strings.TrimSpace(candidate.Track.LanguageCode), preference.LanguageCode) {
				filtered = append(filtered, candidate)
			}
		}
		if len(filtered) > 0 {
			fmt.Printf("[YouTube][Transcript] filtered candidates by language=%q count=%d\n", preference.LanguageCode, len(filtered))
			candidates = filtered
		} else {
			fmt.Printf("[YouTube][Transcript] no candidate for requested language=%q; fallback to auto order\n", preference.LanguageCode)
		}
	}

	for idx, candidate := range candidates {
		fmt.Printf("[YouTube][Transcript] candidate[%d] lang=%q vssId=%q kind=%q priority=%d\n",
			idx,
			strings.TrimSpace(candidate.Track.LanguageCode),
			strings.TrimSpace(candidate.Track.VssID),
			strings.TrimSpace(candidate.Track.Kind),
			candidate.Priority,
		)
	}

	visited := make(map[string]bool, len(candidates))

	for _, candidate := range candidates {
		lang := strings.TrimSpace(candidate.Track.LanguageCode)
		if lang == "" || visited[lang] {
			continue
		}
		visited[lang] = true

		transcript, err := client.GetTranscript(video, lang)
		if err != nil || len(transcript) == 0 {
			fmt.Printf("[YouTube][Transcript] fetch failed lang=%q err=%v\n", lang, err)
			continue
		}

		lrc := transcriptToLRC(video, transcript)
		if strings.TrimSpace(lrc) == "" {
			fmt.Printf("[YouTube][Transcript] transcript empty after transform lang=%q\n", lang)
			continue
		}
		fmt.Printf("[YouTube][Transcript] selected lang=%q vssId=%q segments=%d\n", lang, strings.TrimSpace(candidate.Track.VssID), len(transcript))
		return lrc, lang, strings.TrimSpace(candidate.Track.VssID)
	}

	fmt.Println("[YouTube][Transcript] no transcript selected")
	return "", "", ""
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

// SanitiseForFilename exports filename rules for playlist names and paths.
func SanitiseForFilename(name string) string {
	return sanitizeFilename(name)
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

	captionTracks := buildCaptionTrackInfoList(video.CaptionTracks)
	fmt.Printf("[YouTube][Info] id=%s title=%q tracks=%d\n", video.ID, video.Title, len(captionTracks))
	for _, track := range captionTracks {
		fmt.Printf("[YouTube][Info] track index=%d lang=%q vssId=%q auto=%v kind=%q label=%q\n",
			track.Index, track.LanguageCode, track.VssID, track.IsAuto, track.Kind, track.Label)
	}

	return &YouTubeVideoInfo{
		ID:            video.ID,
		Title:         video.Title,
		Author:        video.Author,
		Duration:      int(video.Duration.Seconds()),
		Thumbnail:     thumbnail,
		Description:   video.Description,
		HubURL:        findHubURL(video.Description),
		Formats:       formats,
		CaptionTracks: captionTracks,
	}, nil
}

// DownloadYouTubeVideo downloads a YouTube video to the specified directory
func DownloadYouTubeVideo(videoURL string, destDir string, audioOnly bool, preference TranscriptPreference) (*YouTubeDownloadResult, error) {
	client := youtube.Client{}
	preference = normaliseTranscriptPreference(preference)
	fmt.Printf("[YouTube][Download] start url=%q audioOnly=%v captionMode=%s captionLang=%q captionVssId=%q\n",
		videoURL, audioOnly, preference.Mode, preference.LanguageCode, preference.VssID)

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

	lyrics, lang, captionTrackVssID := downloadTranscriptAsLRC(&client, video, preference)
	fmt.Printf("[YouTube][Download] transcriptResult hasLyrics=%v lang=%q vssId=%q\n", strings.TrimSpace(lyrics) != "", lang, captionTrackVssID)

	return &YouTubeDownloadResult{
		Path:              destPath,
		Title:             video.Title,
		Artist:            video.Author,
		Duration:          int(video.Duration.Seconds()),
		FileSize:          fileSize,
		Thumbnail:         thumbnail,
		HubURL:            findHubURL(video.Description),
		Lyrics:            lyrics,
		Lang:              lang,
		CaptionTrackVssID: captionTrackVssID,
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
