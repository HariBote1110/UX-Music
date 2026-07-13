import { describe, it, expect } from 'vitest';
import { resolveEmbedPlaybackGain } from './playback-gain.js';

// 公式再生（embed）のラウドネス正規化ゲイン。
// 実効ラウドネス（LUFS）は Go 側が YouTube player response の
// audioConfig から解決する（perceptualLoudnessDb ≒ -14 + loudnessDb）。
describe('resolveEmbedPlaybackGain', () => {
    it('computes gain from target and effective loudness (local と同じ思想)', () => {
        // target -18, effective -7.31 → gainDb = -10.69
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -7.31, targetLoudness: -18 });
        expect(gain).toBeCloseTo(Math.pow(10, -10.69 / 20), 6);
    });

    it('boosts quiet content', () => {
        // target -18, effective -23 → +5 dB
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -23, targetLoudness: -18 });
        expect(gain).toBeCloseTo(Math.pow(10, 5 / 20), 6);
    });

    it('falls back to unity when effective loudness is unavailable', () => {
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: null, targetLoudness: -18 })).toBe(1.0);
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: Number.NaN, targetLoudness: -18 })).toBe(1.0);
    });

    it('defaults target loudness to -18 when invalid', () => {
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness: -13, targetLoudness: Number.NaN });
        expect(gain).toBeCloseTo(Math.pow(10, -5 / 20), 6);
    });

    it('clamps excessive boost to the Go pipeline limit (64x)', () => {
        // effective -120 → gainDb 102 → clamp to 64 (Go 側 maxNormGain と一致)
        expect(resolveEmbedPlaybackGain({ effectiveLoudness: -120, targetLoudness: -18 })).toBe(64);
    });
});
