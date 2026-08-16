import { describe, it, expect } from 'vitest';
import { resolveEmbedPlaybackGain } from './playback-gain.js';

// 公式再生（embed）のラウドネス正規化ゲイン。
// 実効ラウドネス（LUFS）は Go 側が YouTube player response の
// audioConfig から解決する（perceptualLoudnessDb ≒ -14 + loudnessDb）。
//
// 埋め込みプレイヤー自身が自前の正規化減衰を掛けてからタップへ音を渡すため
// （実測: cont −14.6 / tgt −19.0 で video.volume 0.60 = −4.4 dB）、コンテンツ
// ラウドネスをそのまま基準にすると二重に減衰する。ここではプレイヤー通過後の
// ラウドネスを min(コンテンツ, YouTube のターゲット) と推定する。
// 実際の減衰量は再生開始後に Go 側の実測ラウドネス補正が引き取る。
describe('resolveEmbedPlaybackGain', () => {
    it('YouTube のターゲット（-14）より大きいコンテンツは減衰後の値を基準にする', () => {
        // cont -7.31 は YouTube 側で -14 まで下げられて届く → gainDb = -18 -(-14) = -4
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -7.31, targetLoudness: -18 });
        expect(gain).toBeCloseTo(Math.pow(10, -4 / 20), 6);
    });

    it('boosts quiet content', () => {
        // cont -23 は YouTube 側でブーストされない（減衰は片方向）→ +5 dB
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -23, targetLoudness: -18 });
        expect(gain).toBeCloseTo(Math.pow(10, 5 / 20), 6);
    });

    it('falls back to unity when effective loudness is unavailable', () => {
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: null, targetLoudness: -18 })).toBe(1.0);
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: Number.NaN, targetLoudness: -18 })).toBe(1.0);
    });

    it('defaults target loudness to -18 when invalid', () => {
        // cont -13 → 減衰後 -14 とみなす → gainDb = -18 -(-14) = -4
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -13, targetLoudness: Number.NaN });
        expect(gain).toBeCloseTo(Math.pow(10, -4 / 20), 6);
    });

    it('clamps excessive boost to the Go pipeline limit (64x)', () => {
        // effective -120 → gainDb 102 → clamp to 64 (Go 側 maxNormGain と一致)
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: -120, targetLoudness: -18 })).toBe(64);
    });
});
