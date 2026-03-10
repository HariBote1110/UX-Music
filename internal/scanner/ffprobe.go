package scanner

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"ux-music-sidecar/internal/config"
)

type ffprobeStream struct {
	CodecType        string            `json:"codec_type"`
	SampleRate       string            `json:"sample_rate"`
	SampleFormat     string            `json:"sample_fmt"`
	BitsPerSample    int               `json:"bits_per_sample"`
	BitsPerRawSample string            `json:"bits_per_raw_sample"`
	Disposition      map[string]int    `json:"disposition"`
	Tags             map[string]string `json:"tags"`
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
	BitDepth    int
}

var resolvedMediaCommandPaths sync.Map

func isExecutablePath(path string) bool {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return false
	}
	info, err := os.Stat(trimmed)
	if err != nil || info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

func commandBinaryName(name string) string {
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(name), ".exe") {
		return name + ".exe"
	}
	return name
}

func buildCommandFallbackCandidates(name string) []string {
	binaryName := commandBinaryName(name)
	candidates := make([]string, 0, 8)

	executablePath, err := os.Executable()
	if err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(candidates,
			filepath.Clean(filepath.Join(executableDir, "..", "Resources", "bin", binaryName)),
			filepath.Clean(filepath.Join(executableDir, "..", "Resources", binaryName)),
		)
	}

	candidates = append(candidates,
		filepath.Join("/opt/homebrew/bin", binaryName),
		filepath.Join("/usr/local/bin", binaryName),
		filepath.Join("/opt/local/bin", binaryName),
		filepath.Join("/usr/bin", binaryName),
		filepath.Join("/bin", binaryName),
	)

	return candidates
}

func resolveMediaCommandPath(name string) (string, error) {
	if cachedPath, ok := resolvedMediaCommandPaths.Load(name); ok {
		if path, ok := cachedPath.(string); ok && isExecutablePath(path) {
			return path, nil
		}
		resolvedMediaCommandPaths.Delete(name)
	}

	if name == "ffmpeg" && isExecutablePath(config.FFmpegPath) {
		resolvedMediaCommandPaths.Store(name, config.FFmpegPath)
		return config.FFmpegPath, nil
	}
	if name == "ffprobe" && isExecutablePath(config.FFprobePath) {
		resolvedMediaCommandPaths.Store(name, config.FFprobePath)
		return config.FFprobePath, nil
	}

	path, err := exec.LookPath(name)
	if err == nil && isExecutablePath(path) {
		resolvedMediaCommandPaths.Store(name, path)
		return path, nil
	}

	for _, candidate := range buildCommandFallbackCandidates(name) {
		if !isExecutablePath(candidate) {
			continue
		}
		resolvedMediaCommandPaths.Store(name, candidate)
		fmt.Printf("[Scanner] command fallback resolved: %s -> %s\n", name, candidate)
		return candidate, nil
	}

	return "", fmt.Errorf("%s が見つかりません (PATH=%q)", name, os.Getenv("PATH"))
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
		if md.SampleRate == 0 && stream.SampleRate != "" {
			if sampleRate, parseErr := strconv.Atoi(strings.TrimSpace(stream.SampleRate)); parseErr == nil && sampleRate > 0 {
				md.SampleRate = sampleRate
			}
		}
		if md.BitDepth == 0 {
			md.BitDepth = extractBitDepthFromStream(stream)
		}
		if md.SampleRate > 0 && md.BitDepth > 0 {
			break
		}
	}

	return md, nil
}

func extractBitDepthFromStream(stream ffprobeStream) int {
	if stream.BitsPerSample > 0 {
		return stream.BitsPerSample
	}
	if depth := parseLeadingInt(strings.TrimSpace(stream.BitsPerRawSample)); depth > 0 {
		return depth
	}
	return parseBitDepthFromSampleFormat(stream.SampleFormat)
}

func parseBitDepthFromSampleFormat(sampleFormat string) int {
	value := strings.ToLower(strings.TrimSpace(sampleFormat))
	if value == "" {
		return 0
	}

	switch value {
	case "u8", "u8p", "s8", "s8p":
		return 8
	case "s16", "s16p":
		return 16
	case "s24", "s24p":
		return 24
	case "s32", "s32p", "flt", "fltp":
		return 32
	case "s64", "s64p", "dbl", "dblp":
		return 64
	}

	var digits strings.Builder
	for _, r := range value {
		if unicode.IsDigit(r) {
			digits.WriteRune(r)
		}
	}
	if digits.Len() == 0 {
		return 0
	}

	bitDepth, err := strconv.Atoi(digits.String())
	if err != nil || bitDepth <= 0 {
		return 0
	}
	return bitDepth
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
