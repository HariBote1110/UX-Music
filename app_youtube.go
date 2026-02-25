package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/youtube"

	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// GetYouTubeInfo calls the existing GetYouTubeVideoInfo logic
func (a *App) GetYouTubeInfo(url string) (interface{}, error) {
	return youtube.GetYouTubeVideoInfo(url)
}

// AddYouTubeLink は YouTube 動画をダウンロードしてライブラリへ追加する。
func (a *App) AddYouTubeLink(url string) (map[string]interface{}, error) {
	trimmedURL := strings.TrimSpace(url)
	if trimmedURL == "" {
		return nil, fmt.Errorf("YouTubeのURLが空です")
	}

	settings := loadSettingsMap()
	mode := normaliseSettingValue(settings["youtubePlaybackMode"], "download")
	if mode != "download" {
		return nil, fmt.Errorf("現在のWails版では YouTube はダウンロードモードのみ対応しています")
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

	result, err := youtube.DownloadYouTubeVideo(trimmedURL, libraryPath, audioOnly)
	if err != nil {
		return nil, err
	}

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

	subtitleMessage := "字幕が見つからなかったため、同期歌詞は作成されませんでした。"
	if strings.TrimSpace(result.Lyrics) != "" {
		lrcName := fmt.Sprintf("%s.lrc", firstNonEmpty(result.Title, strings.TrimSuffix(filepath.Base(result.Path), filepath.Ext(result.Path))))
		if err := lyrics.SaveLrcFile(lrcName, result.Lyrics); err == nil {
			lang := strings.TrimSpace(result.Lang)
			if lang == "" {
				lang = "auto"
			}
			subtitleMessage = fmt.Sprintf("字幕から同期歌詞を保存しました（言語: %s）。", lang)
		} else {
			subtitleMessage = fmt.Sprintf("字幕は取得できましたが、同期歌詞の保存に失敗しました: %v", err)
		}
	}

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

	rawLibrary, err := store.Instance.Load("library")
	if err != nil {
		return false, nil, err
	}

	library := make([]interface{}, 0)
	if existing, ok := rawLibrary.([]interface{}); ok {
		library = existing
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
