package scanner

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"unicode"
	"ux-music-sidecar/internal/config"
)

type ffprobeStream struct {
	CodecType   string            `json:"codec_type"`
	SampleRate  string            `json:"sample_rate"`
	Disposition map[string]int    `json:"disposition"`
	Tags        map[string]string `json:"tags"`
}

type ffprobeFormat struct {
	Duration string            `json:"duration"`
	Tags     map[string]string `json:"tags"`
}

type ffprobeResult struct {
	Streams []ffprobeStream `json:"streams"`
	Format  ffprobeFormat   `json:"format"`
}

type probedMetadata struct {
	Title       string
	Artist      string
	Album       string
	AlbumArtist string
	Year        int
	Genre       string
	TrackNumber int
	DiscNumber  int
	Duration    float64
	SampleRate  int
}

func resolveMediaCommandPath(name string) (string, error) {
	if name == "ffmpeg" && config.FFmpegPath != "" {
		return config.FFmpegPath, nil
	}
	if name == "ffprobe" && config.FFprobePath != "" {
		return config.FFprobePath, nil
	}

	path, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("%s not found in PATH", name)
	}
	return path, nil
}

func runFFprobe(path string) (ffprobeResult, error) {
	ffprobePath, err := resolveMediaCommandPath("ffprobe")
	if err != nil {
		return ffprobeResult{}, err
	}

	cmd := exec.Command(
		ffprobePath,
		"-v", "error",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		path,
	)
	output, err := cmd.Output()
	if err != nil {
		return ffprobeResult{}, err
	}

	var result ffprobeResult
	if err := json.Unmarshal(output, &result); err != nil {
		return ffprobeResult{}, err
	}
	return result, nil
}

func readMetadataWithFFprobe(path string) (probedMetadata, error) {
	result, err := runFFprobe(path)
	if err != nil {
		return probedMetadata{}, err
	}

	md := probedMetadata{}
	tags := result.Format.Tags

	md.Title = firstNonEmptyTag(tags, "title", "TITLE", "\u00a9nam")
	md.Artist = firstNonEmptyTag(tags, "artist", "ARTIST", "\u00a9ART")
	md.Album = firstNonEmptyTag(tags, "album", "ALBUM", "\u00a9alb")
	md.AlbumArtist = firstNonEmptyTag(tags, "album_artist", "ALBUMARTIST", "album artist", "aART")
	md.Genre = firstNonEmptyTag(tags, "genre", "GENRE", "\u00a9gen")

	if md.TrackNumber == 0 {
		md.TrackNumber = parseLeadingInt(firstNonEmptyTag(tags, "track", "TRACK", "trkn"))
	}
	if md.DiscNumber == 0 {
		md.DiscNumber = parseLeadingInt(firstNonEmptyTag(tags, "disc", "DISC", "disk"))
	}
	md.Year = parseYear(firstNonEmptyTag(tags, "date", "DATE", "year", "YEAR", "\u00a9day"))

	if result.Format.Duration != "" && result.Format.Duration != "N/A" {
		if duration, parseErr := strconv.ParseFloat(strings.TrimSpace(result.Format.Duration), 64); parseErr == nil && duration > 0 {
			md.Duration = duration
		}
	}

	for _, stream := range result.Streams {
		if stream.CodecType != "audio" {
			continue
		}
		if stream.SampleRate != "" {
			if sampleRate, parseErr := strconv.Atoi(strings.TrimSpace(stream.SampleRate)); parseErr == nil && sampleRate > 0 {
				md.SampleRate = sampleRate
				break
			}
		}
	}

	return md, nil
}

func extractArtworkWithFFmpeg(path string) ([]byte, error) {
	ffmpegPath, err := resolveMediaCommandPath("ffmpeg")
	if err != nil {
		return nil, err
	}

	var attempts = [][]string{
		{"-v", "error", "-i", path, "-an", "-map", "0:v:0", "-frames:v", "1", "-f", "image2pipe", "-"},
		{"-v", "error", "-i", path, "-an", "-frames:v", "1", "-f", "image2pipe", "-"},
	}

	for _, args := range attempts {
		cmd := exec.Command(ffmpegPath, args...)
		data, runErr := cmd.Output()
		if runErr == nil && len(data) > 0 {
			return data, nil
		}
	}

	return nil, fmt.Errorf("failed to extract artwork with ffmpeg")
}

func firstNonEmptyTag(tags map[string]string, keys ...string) string {
	if len(tags) == 0 {
		return ""
	}
	for _, key := range keys {
		if value, ok := tags[key]; ok {
			trimmed := strings.TrimSpace(value)
			if trimmed != "" {
				return trimmed
			}
		}
	}
	return ""
}

func parseLeadingInt(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}

	var digits strings.Builder
	for _, r := range value {
		if unicode.IsDigit(r) {
			digits.WriteRune(r)
			continue
		}
		break
	}
	if digits.Len() == 0 {
		return 0
	}

	n, err := strconv.Atoi(digits.String())
	if err != nil {
		return 0
	}
	return n
}

func parseYear(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}

	var digits strings.Builder
	for _, r := range value {
		if unicode.IsDigit(r) {
			digits.WriteRune(r)
		}
	}

	raw := digits.String()
	if len(raw) < 4 {
		return 0
	}
	year, err := strconv.Atoi(raw[:4])
	if err != nil {
		return 0
	}
	return year
}
