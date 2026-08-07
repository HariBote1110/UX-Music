import { describe, expect, it } from 'vitest';

import { computeBarHeights } from './visualizer-mapping.js';

const SAMPLE_RATE = 44100;
const FFT_SIZE = 512; // sourceData length = 256

function makeSilence(): Uint8Array {
    return new Uint8Array(FFT_SIZE / 2);
}

function makeBroadbandLoud(): Uint8Array {
    return new Uint8Array(FFT_SIZE / 2).fill(255);
}

describe('computeBarHeights', () => {
    it('flat silence maps to the minimum 4px for all bars', () => {
        const lastHeights = new Array(6).fill(4);
        const heights = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, lastHeights, 16.7);
        heights.forEach((h) => expect(h).toBeCloseTo(4, 5));
    });

    it('decays gradually after a loud broadband frame, rising faster than it falls', () => {
        const lastHeights = new Array(6).fill(4);

        // Loud frame: heights should rise quickly (fast attack).
        const loudHeights = computeBarHeights(makeBroadbandLoud(), SAMPLE_RATE, FFT_SIZE, lastHeights, 16.7);
        loudHeights.forEach((h) => expect(h).toBeGreaterThan(4));

        // Now silence: heights should decay, but not instantly (slow release).
        const afterOneSilentFrame = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, lastHeights, 16.7);
        afterOneSilentFrame.forEach((h, i) => {
            expect(h).toBeLessThan(loudHeights[i]);
            expect(h).toBeGreaterThan(4); // hasn't fully decayed in a single frame
        });

        // Feed several more silent frames — should keep decaying towards the floor.
        let previous = afterOneSilentFrame;
        for (let i = 0; i < 20; i++) {
            previous = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, lastHeights, 16.7);
        }
        previous.forEach((h) => expect(h).toBeCloseTo(4, 1));

        // Attack must be faster than release: compare per-frame deltas.
        const riseLastHeights = new Array(6).fill(4);
        const riseStep1 = computeBarHeights(makeBroadbandLoud(), SAMPLE_RATE, FFT_SIZE, riseLastHeights, 16.7);
        const riseDelta = riseStep1[0] - 4;

        const fallLastHeights = new Array(6).fill(20);
        const fallStep1 = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, fallLastHeights, 16.7);
        const fallDelta = 20 - fallStep1[0];

        expect(riseDelta).toBeGreaterThan(fallDelta);
    });

    it('treble-only energy moves only the last bars', () => {
        const sourceData = new Uint8Array(FFT_SIZE / 2);
        const binWidth = SAMPLE_RATE / FFT_SIZE; // ~86.1Hz per bin
        // Fill bins corresponding to > 9000Hz (band index 5: [9000, 16000)) with loud energy.
        for (let b = 0; b < sourceData.length; b++) {
            const freq = b * binWidth;
            if (freq >= 9000 && freq < 16000) {
                sourceData[b] = 255;
            }
        }

        const lastHeights = new Array(6).fill(4);
        const heights = computeBarHeights(sourceData, SAMPLE_RATE, FFT_SIZE, lastHeights, 16.7);

        // Low/mid bars (bass/low-mid/mid/upper-mid) should remain at floor.
        expect(heights[0]).toBeCloseTo(4, 5);
        expect(heights[1]).toBeCloseTo(4, 5);
        expect(heights[2]).toBeCloseTo(4, 5);

        // The last (treble) bar should have risen above the floor.
        expect(heights[5]).toBeGreaterThan(4);
    });
});
