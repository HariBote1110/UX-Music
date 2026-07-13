// E2E 検証専用: 環境変数 UX_E2E_YOUTUBE_EMBED_VIDEO が設定されて
// アプリが起動された場合のみ、その動画の公式再生（embed）を自動開始する。
// 合否判定は Go 側 EmbedDebugLog の構造化ログ（scripts/e2e-youtube-embed.sh）が行う。

import { getWailsApp } from '../core/bridge.js';
import { mountEmbedPlayer } from './youtube-embed-player.js';
import { fetchEmbedEffectiveLoudness } from './youtube-embed-loudness.js';
import { resolveEmbedPlaybackGain } from './playback-gain.js';

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
    // 本番経路（player.ts の playEmbed）と同様に、ラウドネス取得を
    // 再生と並行して開始し、タップ開始後に正規化ゲインを適用する。
    const loudnessPromise = fetchEmbedEffectiveLoudness(videoId);
    let tapStarted = false;
    const mounted = await mountEmbedPlayer(videoId, {
        onPlaying: () => {
            void app.EmbedDebugLog?.('e2e-playing');
            if (tapStarted) return;
            tapStarted = true;
            void app.AudioStartWebViewTap?.()
                .then(async () => {
                    const effectiveLoudness = await loudnessPromise;
                    const gain = resolveEmbedPlaybackGain({ effectiveLoudness, targetLoudness: -18 });
                    await app.AudioSetNormalisationGain?.(gain);
                    void app.EmbedDebugLog?.(
                        `e2e-gain loudness=${effectiveLoudness === null ? 'n/a' : effectiveLoudness.toFixed(2)} gain=${gain.toFixed(4)}`
                    );
                })
                .catch((err: unknown) => {
                    void app.EmbedDebugLog?.(`e2e-tap-failed ${String(err)}`);
                });
        },
        onEnded: () => {
            void app.EmbedDebugLog?.('e2e-ended');
        },
    });
    if (!mounted) {
        void app.EmbedDebugLog?.('e2e-mount-failed');
    }
}
