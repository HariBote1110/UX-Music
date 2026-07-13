package server

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/youtube"

	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// GetYouTubeInfo calls the existing GetYouTubeVideoInfo logic
func (a *App) GetYouTubeInfo(url string) (interface{}, error) {
	trimmedURL := strings.TrimSpace(url)
	fmt.Printf("[YouTube][App] GetYouTubeInfo url=%q\n", trimmedURL)
	info, err := youtube.GetYouTubeVideoInfo(trimmedURL)
	if err != nil {
		fmt.Printf("[YouTube][App] GetYouTubeInfo failed: %v\n", err)
		return nil, err
	}
	fmt.Printf("[YouTube][App] GetYouTubeInfo success title=%q captionTracks=%d\n", info.Title, len(info.CaptionTracks))
	return info, nil
}

func extractStringFromMap(data map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value, ok := data[key]; ok {
			if text, ok := value.(string); ok {
				trimmed := strings.TrimSpace(text)
				if trimmed != "" {
					return trimmed
				}
			}
		}
	}
	return ""
}

func parseAddYouTubeLinkPayload(payload interface{}) (string, youtube.TranscriptPreference, error) {
	preference := youtube.TranscriptPreference{Mode: "auto"}

	switch value := payload.(type) {
	case string:
		url := strings.TrimSpace(value)
		if url == "" {
			return "", preference, fmt.Errorf("YouTubeのURLが空です")
		}
		return url, preference, nil
	case map[string]interface{}:
		url := extractStringFromMap(value, "url", "videoUrl", "sourceUrl")
		if url == "" {
			return "", preference, fmt.Errorf("YouTubeのURLが空です")
		}

		preference.Mode = strings.ToLower(extractStringFromMap(value, "captionMode", "mode"))
		if preference.Mode == "" {
			preference.Mode = "auto"
		}
		preference.LanguageCode = extractStringFromMap(value, "captionLanguageCode", "captionLanguage", "languageCode", "language")
		preference.VssID = extractStringFromMap(value, "captionVssId", "captionVssID", "vssId", "vssID")

		if captionRaw, ok := value["caption"].(map[string]interface{}); ok {
			mode := strings.ToLower(extractStringFromMap(captionRaw, "mode"))
			if mode != "" {
				preference.Mode = mode
			}
			languageCode := extractStringFromMap(captionRaw, "languageCode", "language")
			if languageCode != "" {
				preference.LanguageCode = languageCode
			}
			vssID := extractStringFromMap(captionRaw, "vssId", "vssID")
			if vssID != "" {
				preference.VssID = vssID
			}
		}

		return url, preference, nil
	default:
		return "", preference, fmt.Errorf("YouTubeリクエスト形式が不正です")
	}
}

// AddYouTubeLink は YouTube 動画をダウンロードしてライブラリへ追加する。
func (a *App) AddYouTubeLink(payload interface{}) (map[string]interface{}, error) {
	trimmedURL, transcriptPreference, err := parseAddYouTubeLinkPayload(payload)
	if err != nil {
		return nil, err
	}

	fmt.Printf("[YouTube][App] AddYouTubeLink url=%q captionMode=%s captionLanguage=%q captionVssId=%q\n",
		trimmedURL, transcriptPreference.Mode, transcriptPreference.LanguageCode, transcriptPreference.VssID)

	if trimmedURL == "" {
		return nil, fmt.Errorf("YouTubeのURLが空です")
	}

	settings := loadSettingsMap()
	mode := normaliseSettingValue(settings["youtubePlaybackMode"], "download")
	if usesStreamingRegistration(mode) {
		return a.addYouTubeStreamingLink(trimmedURL, mode, transcriptPreference)
	}
	if mode != "download" {
		return nil, fmt.Errorf("未対応のYouTube再生モードです: %s", mode)
	}

	quality := normaliseSettingValue(settings["youtubeDownloadQuality"], "full")
	audioOnly := quality == "audio_only"

	libraryPath, err := a.getOrPromptLibraryPath()
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(libraryPath) == "" {
		return nil, fmt.Errorf("ライブラリフォルダが未設定です")
	}

	result, err := youtube.DownloadYouTubeVideo(trimmedURL, libraryPath, audioOnly, transcriptPreference)
	if err != nil {
		fmt.Printf("[YouTube][App] download failed: %v\n", err)
		return nil, err
	}
	fmt.Printf("[YouTube][App] download completed path=%q title=%q subtitleLang=%q subtitleTrack=%q hasLyrics=%v\n",
		result.Path, result.Title, result.Lang, result.CaptionTrackVssID, strings.TrimSpace(result.Lyrics) != "")

	song := map[string]interface{}{
		"id":        uuid.NewString(),
		"path":      result.Path,
		"title":     firstNonEmpty(result.Title, filepath.Base(result.Path)),
		"artist":    firstNonEmpty(result.Artist, "Unknown Artist"),
		"album":     firstNonEmpty(result.Artist, "YouTube"),
		"duration":  float64(result.Duration),
		"fileSize":  result.FileSize,
		"fileType":  strings.ToLower(filepath.Ext(result.Path)),
		"artwork":   result.Thumbnail,
		"type":      "local",
		"sourceURL": trimmedURL,
		"hasVideo":  !audioOnly,
		"hubUrl":    result.HubURL,
	}

	added, savedSong, err := upsertLibrarySong(song)
	if err != nil {
		return nil, err
	}
	a.queueLoudnessAnalysis([]string{result.Path})

	subtitleMessage := saveYouTubeLyrics(result.Title, result.Path, result.Lyrics, result.Lang, result.CaptionTrackVssID)

	wailsRuntime.EventsEmit(a.ctx, "scan-complete", []interface{}{savedSong})
	wailsRuntime.EventsEmit(a.ctx, "youtube-link-processed", savedSong)
	if added {
		wailsRuntime.EventsEmit(a.ctx, "show-notification", fmt.Sprintf("YouTube楽曲「%s」を追加しました。", result.Title))
	} else {
		wailsRuntime.EventsEmit(a.ctx, "show-notification", fmt.Sprintf("YouTube楽曲「%s」を更新しました。", result.Title))
	}
	wailsRuntime.EventsEmit(a.ctx, "show-notification", subtitleMessage)

	return savedSong, nil
}

// youtubeLyricsFileName は YouTube 楽曲の同期歌詞 LRC ファイル名を返す。
// ダウンロード曲・ストリーミング曲の双方で同一規則を用い、フロントの
// get-lyrics が探索するキー（title、無ければ path のベース名）と一致させる。
// ストリーミング曲は path が動画 URL のため、title を第一キーとする。
func youtubeLyricsFileName(title, path string) string {
	base := strings.TrimSpace(title)
	if base == "" {
		name := filepath.Base(path)
		base = strings.TrimSuffix(name, filepath.Ext(name))
	}
	return base + ".lrc"
}

// saveYouTubeLyrics は取得した LRC をユーザーの Lyrics ディレクトリへ保存し、
// 結果を表す通知文言を返す。字幕が無い場合・保存に失敗した場合も、それぞれの
// 文言を返して呼び出し側の分岐を単純化する。
func saveYouTubeLyrics(title, path, lrc, lang, vssID string) string {
	if strings.TrimSpace(lrc) == "" {
		fmt.Println("[YouTube][App] lyrics not generated")
		return "字幕が見つからなかったため、同期歌詞は作成されませんでした。"
	}
	lrcName := youtubeLyricsFileName(title, path)
	if err := lyrics.SaveLrcFile(lrcName, lrc); err != nil {
		fmt.Printf("[YouTube][App] lyrics save failed: %v\n", err)
		return fmt.Sprintf("字幕は取得できましたが、同期歌詞の保存に失敗しました: %v", err)
	}
	resolvedLang := strings.TrimSpace(lang)
	if resolvedLang == "" {
		resolvedLang = "auto"
	}
	fmt.Printf("[YouTube][App] lyrics saved file=%q lang=%q track=%q\n", lrcName, resolvedLang, vssID)
	return fmt.Sprintf("字幕から同期歌詞を保存しました（言語: %s / track: %s）。", resolvedLang, firstNonEmpty(vssID, "unknown"))
}

// buildStreamingSong はストリーミングモード用の曲エントリを生成する。
// ファイルは保存せず、path に元動画 URL を保持し type を "youtube" とする。
func buildStreamingSong(info *youtube.YouTubeVideoInfo, sourceURL string) map[string]interface{} {
	return map[string]interface{}{
		"id":        uuid.NewString(),
		"path":      sourceURL,
		"title":     firstNonEmpty(info.Title, sourceURL),
		"artist":    firstNonEmpty(info.Author, "Unknown Artist"),
		"album":     "YouTube",
		"duration":  float64(info.Duration),
		"artwork":   info.Thumbnail,
		"type":      "youtube",
		"sourceURL": sourceURL,
		"hasVideo":  true,
		"hubUrl":    info.HubURL,
	}
}

// usesStreamingRegistration はダウンロードせず type:"youtube" の
// エントリとして登録するモード（stream / embed）かどうかを返す。
func usesStreamingRegistration(mode string) bool {
	return mode == "stream" || mode == "embed"
}

// streamingLinkAddedNotification は stream / embed 登録完了時の通知文言を返す。
func streamingLinkAddedNotification(mode, title string, added bool) string {
	if !added {
		return fmt.Sprintf("YouTube楽曲「%s」を更新しました。", title)
	}
	if mode == "embed" {
		return fmt.Sprintf("YouTube楽曲「%s」を公式再生用に追加しました。", title)
	}
	return fmt.Sprintf("YouTube楽曲「%s」をストリーミング再生用に追加しました。", title)
}

// addYouTubeStreamingLink は動画をダウンロードせず、ストリーミング再生用の
// エントリとしてライブラリへ登録する（stream / embed 共通）。
func (a *App) addYouTubeStreamingLink(sourceURL, mode string, transcriptPreference youtube.TranscriptPreference) (map[string]interface{}, error) {
	info, err := youtube.GetYouTubeVideoInfo(sourceURL)
	if err != nil {
		fmt.Printf("[YouTube][App] streaming info fetch failed: %v\n", err)
		return nil, err
	}

	song := buildStreamingSong(info, sourceURL)
	added, savedSong, err := upsertLibrarySong(song)
	if err != nil {
		return nil, err
	}

	// 字幕→LRC 変換はダウンロード経路と同じ規則で行い、embed / stream 曲でも
	// UX Music の歌詞パネルに時刻同期歌詞を表示できるようにする。
	// 取得失敗は致命的ではないため、登録自体は継続する。
	lrc, lang, vssID, transcriptErr := youtube.FetchTranscriptLRC(sourceURL, transcriptPreference)
	if transcriptErr != nil {
		fmt.Printf("[YouTube][App] streaming transcript fetch failed: %v\n", transcriptErr)
	}
	subtitleMessage := saveYouTubeLyrics(info.Title, sourceURL, lrc, lang, vssID)

	wailsRuntime.EventsEmit(a.ctx, "scan-complete", []interface{}{savedSong})
	wailsRuntime.EventsEmit(a.ctx, "youtube-link-processed", savedSong)
	wailsRuntime.EventsEmit(a.ctx, "show-notification", streamingLinkAddedNotification(mode, info.Title, added))
	wailsRuntime.EventsEmit(a.ctx, "show-notification", subtitleMessage)

	return savedSong, nil
}

// ResolveYouTubeStreamURL は動画 URL から再生用の直接ストリーム URL を解決する。
// googlevideo の URL は数時間で失効するため、再生の都度呼び出すこと。
func (a *App) ResolveYouTubeStreamURL(sourceURL string) (string, error) {
	trimmed := strings.TrimSpace(sourceURL)
	if trimmed == "" {
		return "", fmt.Errorf("YouTubeのURLが空です")
	}
	streamURL, err := youtube.GetYouTubeStreamURL(trimmed)
	if err != nil {
		fmt.Printf("[YouTube][App] stream url resolve failed: %v\n", err)
		return "", err
	}
	return streamURL, nil
}

// YouTubeEmbedLoudness は公式再生（embed）のラウドネス正規化用に
// フロントへ返す値。Available=false のときは正規化なしで再生する。
type YouTubeEmbedLoudness struct {
	Available             bool    `json:"available"`
	EffectiveLoudnessLufs float64 `json:"effectiveLoudnessLufs"`
}

// GetYouTubeEmbedLoudness は動画 ID から実効ラウドネス（LUFS）を解決する。
// 取得・解析に失敗しても error にはせず Available=false を返す
// （フロントは正規化なしのフォールバックで通常再生を続けるため）。
func (a *App) GetYouTubeEmbedLoudness(videoID string) YouTubeEmbedLoudness {
	trimmed := strings.TrimSpace(videoID)
	if !embedVideoIDPattern.MatchString(trimmed) {
		return YouTubeEmbedLoudness{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	loudness, err := youtube.FetchEmbedLoudness(ctx, trimmed)
	if err != nil {
		fmt.Printf("[YouTube][Embed] loudness fetch failed video=%s err=%v\n", trimmed, err)
		return YouTubeEmbedLoudness{}
	}
	effective, ok := youtube.EffectiveLoudnessLUFS(loudness)
	if !ok {
		fmt.Printf("[YouTube][Embed] loudness unavailable video=%s\n", trimmed)
		return YouTubeEmbedLoudness{}
	}
	fmt.Printf("[YouTube][Embed] loudness video=%s effectiveLufs=%.2f\n", trimmed, effective)
	return YouTubeEmbedLoudness{Available: true, EffectiveLoudnessLufs: effective}
}

func normaliseSettingValue(value interface{}, fallback string) string {
	if text, ok := value.(string); ok {
		text = strings.TrimSpace(strings.ToLower(text))
		if text != "" {
			return text
		}
	}
	return fallback
}

func upsertLibrarySong(song map[string]interface{}) (bool, map[string]interface{}, error) {
	path, _ := song["path"].(string)
	if strings.TrimSpace(path) == "" {
		return false, nil, fmt.Errorf("保存対象の楽曲パスが空です")
	}

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return false, nil, err
	}

	for idx, item := range library {
		existingSong, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		existingPath, _ := existingSong["path"].(string)
		if existingPath != path {
			continue
		}

		existingID, _ := existingSong["id"].(string)
		for key, value := range song {
			if key == "id" && strings.TrimSpace(existingID) != "" {
				continue
			}
			existingSong[key] = value
		}
		if id, _ := existingSong["id"].(string); strings.TrimSpace(id) == "" {
			existingSong["id"] = uuid.NewString()
		}

		library[idx] = existingSong
		if err := store.Instance.Save("library", library); err != nil {
			return false, nil, err
		}
		return false, existingSong, nil
	}

	if id, _ := song["id"].(string); strings.TrimSpace(id) == "" {
		song["id"] = uuid.NewString()
	}

	library = append(library, song)
	if err := store.Instance.Save("library", library); err != nil {
		return false, nil, err
	}
	return true, song, nil
}
