// 公式再生（embed）用の実効ラウドネス取得。
//
// Go 側 GetYouTubeEmbedLoudness が YouTube player response の
// audioConfig（perceptualLoudnessDb ≒ -14 + loudnessDb）から解決した
// 実効ラウドネス（LUFS）を返す。取得できない動画は null を返し、
// 呼び出し側は正規化なし（ゲイン 1.0）で通常再生する。

import { getWailsApp } from '../core/bridge.js';

export async function fetchEmbedEffectiveLoudness(videoId: string): Promise<number | null> {
    try {
        const result = await getWailsApp()?.GetYouTubeEmbedLoudness?.(videoId);
        if (
            result &&
            result.available === true &&
            typeof result.effectiveLoudnessLufs === 'number' &&
            Number.isFinite(result.effectiveLoudnessLufs)
        ) {
            return result.effectiveLoudnessLufs;
        }
    } catch (error) {
        console.warn('[YouTubeEmbed] ラウドネス取得に失敗しました:', error);
    }
    return null;
}
