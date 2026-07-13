package server

import (
	"testing"
	"ux-music-sidecar/internal/youtube"
)

func TestExtractStringFromMap(t *testing.T) {
	tests := []struct {
		name     string
		data     map[string]interface{}
		keys     []string
		expected string
	}{
		{
			name:     "empty map",
			data:     map[string]interface{}{},
			keys:     []string{"key1"},
			expected: "",
		},
		{
			name: "single key found",
			data: map[string]interface{}{
				"key1": "value1",
			},
			keys:     []string{"key1"},
			expected: "value1",
		},
		{
			name: "single key found with surrounding spaces",
			data: map[string]interface{}{
				"key1": "  value1  ",
			},
			keys:     []string{"key1"},
			expected: "value1",
		},
		{
			name: "multiple keys, first found",
			data: map[string]interface{}{
				"key1": "value1",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value1",
		},
		{
			name: "multiple keys, second found",
			data: map[string]interface{}{
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but not a string",
			data: map[string]interface{}{
				"key1": 123,
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but empty string",
			data: map[string]interface{}{
				"key1": "",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but only spaces",
			data: map[string]interface{}{
				"key1": "   ",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "no keys match",
			data: map[string]interface{}{
				"key3": "value3",
			},
			keys:     []string{"key1", "key2"},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractStringFromMap(tt.data, tt.keys...)
			if result != tt.expected {
				t.Errorf("extractStringFromMap() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestNormaliseSettingValue(t *testing.T) {
	tests := []struct {
		name     string
		value    interface{}
		fallback string
		want     string
	}{
		{
			name:     "valid string",
			value:    "  FULL  ",
			fallback: "download",
			want:     "full",
		},
		{
			name:     "valid string already normalized",
			value:    "audio_only",
			fallback: "full",
			want:     "audio_only",
		},
		{
			name:     "empty string",
			value:    "",
			fallback: "download",
			want:     "download",
		},
		{
			name:     "whitespace string",
			value:    "   \n\t ",
			fallback: "fallback_val",
			want:     "fallback_val",
		},
		{
			name:     "nil value",
			value:    nil,
			fallback: "default",
			want:     "default",
		},
		{
			name:     "integer value",
			value:    123,
			fallback: "default",
			want:     "default",
		},
		{
			name:     "boolean value",
			value:    true,
			fallback: "default",
			want:     "default",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normaliseSettingValue(tt.value, tt.fallback)
			if got != tt.want {
				t.Errorf("normaliseSettingValue() = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestBuildStreamingSong はストリーミングモードで登録される曲エントリの
// 生成を検証する。ダウンロードせず、path に元動画 URL を保持し、
// type を "youtube" とすることでフロントエンドがストリーム再生へ振り分ける。
func TestBuildStreamingSong(t *testing.T) {
	info := &youtube.YouTubeVideoInfo{
		ID:        "dQw4w9WgXcQ",
		Title:     "Never Gonna Give You Up",
		Author:    "Rick Astley",
		Duration:  213,
		Thumbnail: "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
		HubURL:    "https://lnk.to/example",
	}
	sourceURL := "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

	song := buildStreamingSong(info, sourceURL)

	if got, _ := song["type"].(string); got != "youtube" {
		t.Errorf("type = %q, want %q", got, "youtube")
	}
	if got, _ := song["path"].(string); got != sourceURL {
		t.Errorf("path = %q, want %q", got, sourceURL)
	}
	if got, _ := song["sourceURL"].(string); got != sourceURL {
		t.Errorf("sourceURL = %q, want %q", got, sourceURL)
	}
	if got, _ := song["title"].(string); got != info.Title {
		t.Errorf("title = %q, want %q", got, info.Title)
	}
	if got, _ := song["artist"].(string); got != info.Author {
		t.Errorf("artist = %q, want %q", got, info.Author)
	}
	if got, _ := song["album"].(string); got != "YouTube" {
		t.Errorf("album = %q, want %q", got, "YouTube")
	}
	if got, _ := song["duration"].(float64); got != 213 {
		t.Errorf("duration = %v, want 213", got)
	}
	if got, _ := song["artwork"].(string); got != info.Thumbnail {
		t.Errorf("artwork = %q, want %q", got, info.Thumbnail)
	}
	if got, _ := song["hubUrl"].(string); got != info.HubURL {
		t.Errorf("hubUrl = %q, want %q", got, info.HubURL)
	}
	if got, _ := song["id"].(string); got == "" {
		t.Error("id should not be empty")
	}
}

// TestBuildStreamingSongFallbacks は情報欠落時の既定値を検証する。
func TestBuildStreamingSongFallbacks(t *testing.T) {
	info := &youtube.YouTubeVideoInfo{ID: "abc123"}
	song := buildStreamingSong(info, "https://youtu.be/abc123")

	if got, _ := song["title"].(string); got == "" {
		t.Error("title should fall back to a non-empty value")
	}
	if got, _ := song["artist"].(string); got != "Unknown Artist" {
		t.Errorf("artist = %q, want %q", got, "Unknown Artist")
	}
}

// TestYoutubeLyricsFileName は LRC 保存ファイル名の規則を検証する。
// ダウンロード曲・ストリーミング曲の双方で同一規則を用い、
// get-lyrics の探索キー（title もしくは path のベース名）と一致させる必要がある。
func TestYoutubeLyricsFileName(t *testing.T) {
	tests := []struct {
		name  string
		title string
		path  string
		want  string
	}{
		{
			name:  "download song uses title",
			title: "My Song",
			path:  "/Library/Artist/My Song.m4a",
			want:  "My Song.lrc",
		},
		{
			name:  "streaming song uses title even when path is a URL",
			title: "My Song",
			path:  "https://www.youtube.com/watch?v=abc123",
			want:  "My Song.lrc",
		},
		{
			name:  "empty title falls back to path basename without extension",
			title: "",
			path:  "/Library/Artist/Fallback Title.m4a",
			want:  "Fallback Title.lrc",
		},
		{
			name:  "empty title with URL path falls back to raw last segment",
			title: "   ",
			path:  "https://youtu.be/xyz",
			want:  "xyz.lrc",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := youtubeLyricsFileName(tt.title, tt.path); got != tt.want {
				t.Errorf("youtubeLyricsFileName(%q, %q) = %q, want %q", tt.title, tt.path, got, tt.want)
			}
		})
	}
}

func TestUsesStreamingRegistration(t *testing.T) {
	tests := []struct {
		mode string
		want bool
	}{
		{"stream", true},
		{"embed", true},
		{"download", false},
		{"", false},
		{"unknown", false},
	}
	for _, tt := range tests {
		if got := usesStreamingRegistration(tt.mode); got != tt.want {
			t.Errorf("usesStreamingRegistration(%q) = %v, want %v", tt.mode, got, tt.want)
		}
	}
}

func TestStreamingLinkAddedNotification(t *testing.T) {
	tests := []struct {
		name  string
		mode  string
		title string
		added bool
		want  string
	}{
		{
			name:  "embed added",
			mode:  "embed",
			title: "Song",
			added: true,
			want:  "YouTube楽曲「Song」を公式再生用に追加しました。",
		},
		{
			name:  "stream added",
			mode:  "stream",
			title: "Song",
			added: true,
			want:  "YouTube楽曲「Song」をストリーミング再生用に追加しました。",
		},
		{
			name:  "updated ignores mode",
			mode:  "embed",
			title: "Song",
			added: false,
			want:  "YouTube楽曲「Song」を更新しました。",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := streamingLinkAddedNotification(tt.mode, tt.title, tt.added); got != tt.want {
				t.Errorf("streamingLinkAddedNotification() = %q, want %q", got, tt.want)
			}
		})
	}
}
