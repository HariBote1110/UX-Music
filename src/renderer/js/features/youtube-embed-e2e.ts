// E2E 検証専用: 環境変数 UX_E2E_YOUTUBE_EMBED_VIDEO が設定されて
// アプリが起動された場合のみ、その動画の公式再生（embed）を自動開始する。
// 合否判定は Go 側 EmbedDebugLog の構造化ログ（scripts/e2e-youtube-embed.sh）が行う。

import { getWailsApp } from '../core/bridge.js';
import { mountEmbedPlayer } from './youtube-embed-player.js';

export async function runYouTubeEmbedE2E(): Promise<void> {
    const app = getWailsApp();
    if (!app?.GetE2EEmbedVideoID) return;

    let videoId = '';
    try {
        videoId = (await app.GetE2EEmbedVideoID()) ?? '';
    } catch {
        return;
    }
    if (videoId === '') return;

    void app.EmbedDebugLog?.(`e2e-start video=${videoId}`);
    const mounted = await mountEmbedPlayer(videoId, {
        onPlaying: () => {
            void app.EmbedDebugLog?.('e2e-playing');
        },
        onEnded: () => {
            void app.EmbedDebugLog?.('e2e-ended');
        },
    });
    if (!mounted) {
        void app.EmbedDebugLog?.('e2e-mount-failed');
    }
}
