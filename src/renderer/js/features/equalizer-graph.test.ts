import { describe, expect, it } from 'vitest';
import { applyEqualizerToGraph } from './equalizer-graph.js';

describe('applyEqualizerToGraph', () => {
    it('writes preamp and band gains to a newly activated graph', () => {
        const writes: Array<{ value: number; time: number }> = [];
        const graph = {
            context: { currentTime: 12 },
            nodes: {
                preamp: {
                    gain: { setValueAtTime: (value: number, time: number) => writes.push({ value, time }) },
                },
                eqBands: Array.from({ length: 10 }, () => ({
                    gain: { setValueAtTime: (value: number, time: number) => writes.push({ value, time }) },
                })),
            },
        };

        applyEqualizerToGraph(graph, { preamp: 6, bands: [1, 2, 3] });

        expect(writes[0].value).toBeCloseTo(Math.pow(10, 6 / 20), 10);
        expect(writes.slice(1, 4).map(write => write.value)).toEqual([1, 2, 3]);
        expect(writes.every(write => write.time === 12)).toBe(true);
    });
});
