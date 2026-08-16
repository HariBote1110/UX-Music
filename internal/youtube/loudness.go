package youtube

// YouTube 公式再生（embed）用のラウドネス取得。
//
// 公式プレイヤーはファイルを事前解析できないため、YouTube 自身が
// player response に持つ実測ラウドネス値（playerConfig.audioConfig）を使う。
// kkdai/youtube は同じ innertube /player エンドポイントを叩くが、この
// フィールドを構造体に持たないため、ここで軽量な自前呼び出しを行う。
//
// 値の解釈（2026-07-13 実測により確認）:
//   - loudnessDb は「YouTube の基準ラウドネス -14 LUFS に対する相対値」。
//   - perceptualLoudnessDb = -14 + loudnessDb がコンテンツの実効ラウドネス
//     （統合 LUFS）に一致する。例: 9bZkp7q19f0 は perceptualLoudnessDb=-7.31、
//     同動画の音声を ffmpeg ebur128 で解析した統合ラウドネスは -7.3 LUFS。
//   - 本実装は perceptualLoudnessDb を優先し、無ければ -14 + loudnessDb で
//     導出する。埋め込みプレイヤー自身が減衰を掛けているかは確定できて
//     いない（E2E 環境では自動再生がミュートされ計測不能）ため、ソース
//     音源そのもののラウドネスとして扱う。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
)

// EmbedLoudness は player response の audioConfig から取れたラウドネス値。
// フィールドが応答に無い場合は nil。
type EmbedLoudness struct {
	LoudnessDb           *float64
	PerceptualLoudnessDb *float64
}

// loudnessReferenceLUFS は YouTube の基準ラウドネス（-14 LUFS）。
const loudnessReferenceLUFS = -14.0

// parseEmbedLoudness は innertube /player 応答の JSON から
// playerConfig.audioConfig のラウドネス値を取り出す。
// 解析に失敗した場合は空の EmbedLoudness を返す。
func parseEmbedLoudness(body []byte) EmbedLoudness {
	var parsed struct {
		PlayerConfig struct {
			AudioConfig struct {
				LoudnessDb           *float64 `json:"loudnessDb"`
				PerceptualLoudnessDb *float64 `json:"perceptualLoudnessDb"`
			} `json:"audioConfig"`
		} `json:"playerConfig"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return EmbedLoudness{}
	}
	return EmbedLoudness{
		LoudnessDb:           parsed.PlayerConfig.AudioConfig.LoudnessDb,
		PerceptualLoudnessDb: parsed.PlayerConfig.AudioConfig.PerceptualLoudnessDb,
	}
}

// EffectiveLoudnessLUFS はコンテンツの実効ラウドネス（LUFS）を返す。
// perceptualLoudnessDb を優先し、無ければ -14 + loudnessDb で導出する。
// どちらも取れない（または非有限値の）場合は ok=false。
func EffectiveLoudnessLUFS(l EmbedLoudness) (float64, bool) {
	if l.PerceptualLoudnessDb != nil && isFinite(*l.PerceptualLoudnessDb) {
		return *l.PerceptualLoudnessDb, true
	}
	if l.LoudnessDb != nil && isFinite(*l.LoudnessDb) {
		return loudnessReferenceLUFS + *l.LoudnessDb, true
	}
	return 0, false
}

func isFinite(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0)
}

// innertube ANDROID クライアント設定。kkdai/youtube v2.10.5 が使う値と
// 同一（WEB クライアントは audioConfig を返さないため ANDROID を使う）。
const (
	innertubePlayerURL       = "https://www.youtube.com/youtubei/v1/player?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
	innertubeAndroidVersion  = "20.10.38"
	innertubeAndroidUserAgnt = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
)

// FetchEmbedLoudness は innertube /player を呼び、動画のラウドネス値を返す。
// ネットワーク・解析エラー時は error を返す（呼び出し側は正規化なしへ
// フォールバックする想定）。
func FetchEmbedLoudness(ctx context.Context, videoID string) (EmbedLoudness, error) {
	payload := map[string]interface{}{
		"context": map[string]interface{}{
			"client": map[string]interface{}{
				"hl":               "en",
				"gl":               "US",
				"clientName":       "ANDROID",
				"clientVersion":    innertubeAndroidVersion,
				"userAgent":        innertubeAndroidUserAgnt,
				"timeZone":         "UTC",
				"utcOffsetMinutes": 0,
			},
		},
		"videoId":        videoID,
		"contentCheckOk": true,
		"racyCheckOk":    true,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return EmbedLoudness{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, innertubePlayerURL, bytes.NewReader(body))
	if err != nil {
		return EmbedLoudness{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", innertubeAndroidUserAgnt)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return EmbedLoudness{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return EmbedLoudness{}, fmt.Errorf("innertube player request failed: status=%d", resp.StatusCode)
	}

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return EmbedLoudness{}, err
	}
	return parseEmbedLoudness(respBody), nil
}
