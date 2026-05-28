import { describe, expect, it } from 'vitest';
import { buildSkipEvent } from './playback-skip.js';
import { resolveLocalPlaybackGain } from './playback-gain.js';

describe('resolveLocalPlaybackGain', () => {
    it('computes Wails playback gain even when forcePlay is enabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: -24,
            targetLoudness: -18,
            forcePlay: true
        });

        expect(result.shouldWaitForAnalysis).toBe(false);
        expect(result.gainLinear).toBeCloseTo(Math.pow(10, 6 / 20), 10);
    });

    it('waits for loudness analysis when the value is missing and forcePlay is disabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: null,
            targetLoudness: -18,
            forcePlay: false
        });

        expect(result.shouldWaitForAnalysis).toBe(true);
        expect(result.gainLinear).toBe(1);
    });

    it('does not wait for loudness analysis when the value is missing and forcePlay is enabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: undefined,
            targetLoudness: -18,
            forcePlay: true
        });

        expect(result.shouldWaitForAnalysis).toBe(false);
        expect(result.gainLinear).toBe(1);
    });
});

describe('buildSkipEvent', () => {
    it('builds skip payload from backend playback time without requiring a media element', () => {
        const song = { id: 'song-1', title: 'Skip Me', duration: 200 };
        expect(buildSkipEvent({
            analysedQueueEnabled: true,
            currentSongIndex: 0,
            skippedSong: song,
            currentTime: 12.5,
            duration: 200,
        })).toEqual({ song, currentTime: 12.5 });
    });
});
