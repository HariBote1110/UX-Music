import { describe, expect, it } from 'vitest';

import { computeBarHeights, createVisualizerState } from './visualizer-mapping.js';

const SAMPLE_RATE = 44100;
const FFT_SIZE = 512; // sourceData length = 256

function makeSilence(): Uint8Array {
    return new Uint8Array(FFT_SIZE / 2);
}

function makeBroadbandLoud(): Uint8Array {
    return new Uint8Array(FFT_SIZE / 2).fill(255);
}

/** dBスケール値 v (0-255) を broadband に均一適用したデータを作る。 */
function makeBroadband(value: number): Uint8Array {
    return new Uint8Array(FFT_SIZE / 2).fill(value);
}

describe('computeBarHeights', () => {
    it('flat silence maps to the minimum 4px for all bars', () => {
        const state = createVisualizerState();
        const heights = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        heights.forEach((h) => expect(h).toBeCloseTo(4, 5));
    });

    it('silence does not inflate the envelope (still floors at 4px after loud then silent frames)', () => {
        const state = createVisualizerState();
        computeBarHeights(makeBroadbandLoud(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        // Many silent frames afterwards should decay straight back to floor,
        // proving silence itself never raises the envelope.
        let heights = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        for (let i = 0; i < 300; i++) {
            heights = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        }
        heights.forEach((h) => expect(h).toBeCloseTo(4, 1));
    });

    it('decays gradually after a loud broadband frame, rising faster than it falls', () => {
        const state = createVisualizerState();

        // Loud frame: heights should rise quickly (fast attack).
        const loudHeights = computeBarHeights(makeBroadbandLoud(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        loudHeights.forEach((h) => expect(h).toBeGreaterThan(4));

        // Now silence: heights should decay, but not instantly (slow release).
        const afterOneSilentFrame = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        afterOneSilentFrame.forEach((h, i) => {
            expect(h).toBeLessThan(loudHeights[i]);
            expect(h).toBeGreaterThan(4); // hasn't fully decayed in a single frame
        });

        // Feed several more silent frames — should keep decaying towards the floor.
        let previous = afterOneSilentFrame;
        for (let i = 0; i < 60; i++) {
            previous = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        }
        previous.forEach((h) => expect(h).toBeLessThan(4.05));

        // Attack must be faster than release: compare per-frame deltas.
        const riseState = createVisualizerState();
        const riseStep1 = computeBarHeights(makeBroadbandLoud(), SAMPLE_RATE, FFT_SIZE, riseState, 16.7);
        const riseDelta = riseStep1[0] - 4;

        const fallState = createVisualizerState();
        fallState.lastHeights.fill(20);
        fallState.envelope.fill(1);
        const fallStep1 = computeBarHeights(makeSilence(), SAMPLE_RATE, FFT_SIZE, fallState, 16.7);
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

        const state = createVisualizerState();
        const heights = computeBarHeights(sourceData, SAMPLE_RATE, FFT_SIZE, state, 16.7);

        // Low/mid bars (bass/low-mid/mid/upper-mid) should remain at floor.
        expect(heights[0]).toBeCloseTo(4, 5);
        expect(heights[1]).toBeCloseTo(4, 5);
        expect(heights[2]).toBeCloseTo(4, 5);

        // The last (treble) bar should have risen above the floor.
        expect(heights[5]).toBeGreaterThan(4);
    });

    it('shows relative dynamics: a moderately-loud frame after a loud frame maps clearly lower', () => {
        const state = createVisualizerState();

        // First, a very loud frame establishes a high envelope peak.
        const loudHeights = computeBarHeights(makeBroadband(255), SAMPLE_RATE, FFT_SIZE, state, 16.7);

        // Let heights settle near their target by feeding the same loud level again.
        for (let i = 0; i < 30; i++) {
            computeBarHeights(makeBroadband(255), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        }
        const settledLoud = computeBarHeights(makeBroadband(255), SAMPLE_RATE, FFT_SIZE, state, 16.7);

        // Now a moderately-loud frame (~60% of the loud ratio, still well above the noise gate).
        const moderateValue = 190; // v ≈ 0.745, u ≈ (0.745-0.22)/0.78 ≈ 0.673 vs loud u ≈ 1
        const moderateHeights = computeBarHeights(makeBroadband(moderateValue), SAMPLE_RATE, FFT_SIZE, state, 16.7);

        expect(loudHeights[0]).toBeGreaterThan(4);
        moderateHeights.forEach((h, i) => {
            expect(h).toBeLessThan(settledLoud[i]);
        });
    });

    it('recovers upward once the envelope decays: the same moderate input maps higher after a long quiet stretch', () => {
        const state = createVisualizerState();

        // Establish a high envelope peak.
        for (let i = 0; i < 5; i++) {
            computeBarHeights(makeBroadband(255), SAMPLE_RATE, FFT_SIZE, state, 16.7);
        }

        const moderateValue = 190;

        // Immediately after the loud peak, the moderate frame is suppressed relative to the envelope.
        const suppressedHeights = computeBarHeights(makeBroadband(moderateValue), SAMPLE_RATE, FFT_SIZE, state, 16.7);

        // Reset heights toward floor artificially isn't needed — instead let the envelope
        // decay across a long silent/moderate span using a large dtMs jump (several seconds).
        const recoveringState = createVisualizerState();
        for (let i = 0; i < 5; i++) {
            computeBarHeights(makeBroadband(255), SAMPLE_RATE, FFT_SIZE, recoveringState, 16.7);
        }
        // Big time jump: several half-lives of decay (4s half-life -> 12s = 3 half-lives).
        computeBarHeights(makeBroadband(moderateValue), SAMPLE_RATE, FFT_SIZE, recoveringState, 12000);
        // Now feed the moderate value again at a normal frame interval so the smoothing
        // has a chance to approach its (now higher) target.
        let recoveredHeights = recoveringState.lastHeights.slice();
        for (let i = 0; i < 30; i++) {
            recoveredHeights = computeBarHeights(makeBroadband(moderateValue), SAMPLE_RATE, FFT_SIZE, recoveringState, 16.7);
        }

        recoveredHeights.forEach((h, i) => {
            expect(h).toBeGreaterThan(suppressedHeights[i]);
        });
    });
});
