import { beforeAll, describe, expect, it } from 'vitest';

// レガシー経路のシャッフル開始: 開始曲を先頭に置き、残りをランダム化する。
// 重複 ID や ID 未設定の曲を誤って除去・統合しないこと（位置で除外する）。

beforeAll(() => {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
});

async function loadBuilder() {
    const mod = await import('./playback-manager.js');
    return mod.buildShuffledStartQueue;
}

describe('buildShuffledStartQueue', () => {
    it('keeps the same length and starts with the chosen song', async () => {
        const buildShuffledStartQueue = await loadBuilder();
        const source = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }];
        const result = buildShuffledStartQueue(source, 2, () => 0.5);
        expect(result).toHaveLength(source.length);
        expect(result[0]).toBe(source[2]);
    });

    it('keeps every occurrence when the same id appears more than once', async () => {
        const buildShuffledStartQueue = await loadBuilder();
        const source = [
            { id: 'dup', title: 'first' },
            { id: 'other', title: 'mid' },
            { id: 'dup', title: 'second' },
            { id: 'dup', title: 'third' },
        ];
        const result = buildShuffledStartQueue(source, 0, () => 0.99);
        expect(result).toHaveLength(source.length);
        expect(result[0]).toBe(source[0]);
        expect(result.map(s => s.title).sort()).toEqual(source.map(s => s.title).sort());
    });

    it('does not collapse songs without an id', async () => {
        const buildShuffledStartQueue = await loadBuilder();
        const source: Array<{ id?: string; title: string }> = [
            { title: 'x' },
            { title: 'y' },
            { title: 'z' },
        ];
        const result = buildShuffledStartQueue(source, 1, () => 0);
        expect(result).toHaveLength(3);
        expect(result[0]).toBe(source[1]);
        expect(result.map(s => s.title).sort()).toEqual(['x', 'y', 'z']);
    });

    it('returns a permutation of the input for any random sequence', async () => {
        const buildShuffledStartQueue = await loadBuilder();
        const source = [{ id: 'a' }, { id: 'a' }, { id: undefined }, { id: 'b' }, {}];
        let seed = 7;
        const random = () => {
            seed = (seed * 16807) % 2147483647;
            return seed / 2147483647;
        };
        const result = buildShuffledStartQueue(source, 3, random);
        expect(result).toHaveLength(source.length);
        expect(result[0]).toBe(source[3]);
        for (const item of source) {
            expect(result.filter(r => r === item)).toHaveLength(1);
        }
    });
});
