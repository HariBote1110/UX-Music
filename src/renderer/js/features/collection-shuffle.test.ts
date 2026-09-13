import { beforeEach, describe, expect, it, vi } from 'vitest';

beforeEach(() => {
    vi.resetModules();
    (window as unknown as { go?: unknown }).go = undefined;
});

describe('resolveEffectiveShuffle', () => {
    it.each([
        [false, null, true, false],
        [false, 'on', true, true],
        [true, 'off', true, false],
        [true, 'off', false, true],
    ] as const)('uses the collection preference only for a new queue', async (baseline, preference, isNewQueue, expected) => {
        const { resolveEffectiveShuffle } = await import('./collection-shuffle.js');
        expect(resolveEffectiveShuffle(baseline, preference, isNewQueue)).toBe(expected);
    });
});

describe('collection shuffle cache', () => {
    it('loads, updates, and notifies listeners through the Go binding', async () => {
        const get = vi.fn(async () => ({ 'album:album-key': 'on' }));
        const set = vi.fn(async () => {});
        (window as unknown as { go: unknown }).go = { server: { App: {
            GetCollectionShufflePreferences: get,
            SetCollectionShufflePreference: set,
        } } };
        const module = await import('./collection-shuffle.js');
        const listener = vi.fn();
        module.subscribeCollectionShufflePreferences(listener);

        await module.loadCollectionShufflePreferences();
        expect(module.getCollectionShufflePreference({ kind: 'album', key: 'album-key' })).toBe('on');
        await module.setCollectionShufflePreference({ kind: 'album', key: 'album-key' }, 'off');

        expect(set).toHaveBeenCalledWith('album', 'album-key', 'off');
        expect(module.getCollectionShufflePreference({ kind: 'album', key: 'album-key' })).toBe('off');
        expect(listener).toHaveBeenCalledTimes(2);
    });
});
