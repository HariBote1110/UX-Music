// E2E 検証専用: 環境変数 UX_E2E_YOUTUBE_EMBED_VIDEO が設定されて
// アプリが起動された場合のみ、その動画の公式再生（embed）を自動開始する。
// 合否判定は Go 側 EmbedDebugLog の構造化ログ（scripts/e2e-youtube-embed.sh）が行う。

import { getWailsApp } from '../core/bridge.js';
import { mountEmbedPlayer } from './youtube-embed-player.js';
import { fetchEmbedEffectiveLoudness } from './youtube-embed-loudness.js';
import { resolveEmbedPlaybackGain } from './playback-gain.js';

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * タップ出力（processAudio 後）の RMS を一定時間サンプリングして平均する。
 * 出力に volume が乗っていれば、音量 2 段階で平均 RMS が比例して変わる。
 */
async function averageOutputRMS(app: NonNullable<ReturnType<typeof getWailsApp>>, samples: number, intervalMs: number): Promise<number> {
    let sum = 0;
    let count = 0;
    for (let i = 0; i < samples; i++) {
        try {
            const rms = await app.AudioDebugOutputRMS?.();
            if (typeof rms === 'number' && Number.isFinite(rms)) {
                sum += rms;
                count += 1;
            }
        } catch {
            /* 計測失敗のサンプルは除外 */
        }
        await sleep(intervalMs);
    }
    return count > 0 ? sum / count : 0;
}

/**
 * AudioSetVolume を 2 段階（1.0 → 0.25）で設定し、出力 RMS が比例して
 * 変わることを構造化ログ（e2e-volume …）として報告する。判定はシェル側。
 */
async function runVolumeCheck(app: NonNullable<ReturnType<typeof getWailsApp>>): Promise<void> {
    // タップ音声が安定して流れ始めるまで待つ
    await sleep(3000);

    await app.AudioSetVolume?.(1.0);
    await sleep(500);
    const rmsFull = await averageOutputRMS(app, 12, 100);

    await app.AudioSetVolume?.(0.25);
    await sleep(500);
    const rmsQuarter = await averageOutputRMS(app, 12, 100);

    await app.AudioSetVolume?.(1.0);

    if (rmsFull <= 1e-6) {
        // 自動再生ミュート等で音が流れない環境では比例判定ができない
        void app.EmbedDebugLog?.(`e2e-volume-skip rmsFull=${rmsFull.toFixed(6)} (no audible output)`);
        return;
    }
    const ratio = rmsQuarter / rmsFull;
    void app.EmbedDebugLog?.(
        `e2e-volume rmsFull=${rmsFull.toFixed(6)} rmsQuarter=${rmsQuarter.toFixed(6)} ratio=${ratio.toFixed(4)}`
    );
}

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
    // ただし実測ラウドネス補正（AudioStartLiveLoudnessCorrection）は起動しない。
    // 補正は時間とともにゲインを動かすため、後段の runVolumeCheck が見る出力 RMS が
    // 測定タイミング依存になってしまう。ここでは推定ゲインのみを決定的に検証する。
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
                    await runVolumeCheck(app);
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
