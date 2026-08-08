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

        // preamp のデシベル値を線形ゲインへ変換する: gain = 10^(dB/20)、+6dB ≒ 1.9953倍。
        // 実装式をそのまま書くと同語反復になるため、期待値はリテラルで固定する。
        expect(writes[0].value).toBeCloseTo(1.9952623149688795, 10);
        expect(writes.slice(1, 4).map(write => write.value)).toEqual([1, 2, 3]);
        expect(writes.every(write => write.time === 12)).toBe(true);
    });
});
