package server

// YouTube 公式再生（embed）モードの補助バインディング。
// E2E 検証用の構造化ログ出力と、自動再生フック用の動画 ID 取得を提供する。

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// EmbedDebugLog は renderer からの埋め込みプレイヤーイベントを
// 構造化ログとして標準出力へ書き出す。E2E スクリプトはこの行を
// 監視して合否を判定する。
func (a *App) EmbedDebugLog(message string) {
	fmt.Printf("[E2E][YouTubeEmbed] %s ts=%s\n", message, time.Now().Format(time.RFC3339))
}

// GetE2EEmbedVideoID は環境変数 UX_E2E_YOUTUBE_EMBED_VIDEO の値を返す。
// 非空のとき、renderer は起動直後にその動画の公式再生を自動開始する
// （E2E 検証専用の導線。通常利用では常に空）。
func (a *App) GetE2EEmbedVideoID() string {
	return strings.TrimSpace(os.Getenv("UX_E2E_YOUTUBE_EMBED_VIDEO"))
}
