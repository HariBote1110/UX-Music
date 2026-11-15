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

    it('keeps the cached Map when the Go binding is unavailable', async () => {
        const app = { GetCollectionShufflePreferences: vi.fn(async () => ({ 'album:album-key': 'on' })) };
        (window as unknown as { go: unknown }).go = { server: { App: app } };
        const module = await import('./collection-shuffle.js');
        const listener = vi.fn();
        module.subscribeCollectionShufflePreferences(listener);
        await module.loadCollectionShufflePreferences();
        expect(listener).toHaveBeenCalledTimes(1);

        (window as unknown as { go: unknown }).go = { server: { App: {} } };
        await module.loadCollectionShufflePreferences();

        expect(module.getCollectionShufflePreference({ kind: 'album', key: 'album-key' })).toBe('on');
        expect(listener).toHaveBeenCalledTimes(1);
    });

    it('does not let a load in flight overwrite a set that completed meanwhile', async () => {
        let resolveLoad!: (value: Record<string, unknown>) => void;
        const get = vi.fn(() => new Promise<Record<string, unknown>>(resolve => {
            resolveLoad = resolve;
        }));
        const set = vi.fn(async () => {});
        (window as unknown as { go: unknown }).go = { server: { App: {
            GetCollectionShufflePreferences: get,
            SetCollectionShufflePreference: set,
        } } };
        const module = await import('./collection-shuffle.js');
        const ref = { kind: 'album', key: 'album-key' } as const;

        const loading = module.loadCollectionShufflePreferences();
        await module.setCollectionShufflePreference(ref, 'off');
        resolveLoad({ 'album:album-key': 'on' });
        await loading;

        expect(module.getCollectionShufflePreference(ref)).toBe('off');
    });

    it('does not let a load in flight restore a preference that a set deleted meanwhile', async () => {
        let resolveLoad!: (value: Record<string, unknown>) => void;
        const get = vi.fn(() => new Promise<Record<string, unknown>>(resolve => {
            resolveLoad = resolve;
        }));
        const set = vi.fn(async () => {});
        (window as unknown as { go: unknown }).go = { server: { App: {
            GetCollectionShufflePreferences: get,
            SetCollectionShufflePreference: set,
        } } };
        const module = await import('./collection-shuffle.js');
        const ref = { kind: 'playlist', key: 'pl-key' } as const;

        const loading = module.loadCollectionShufflePreferences();
        await module.setCollectionShufflePreference(ref, null);
        resolveLoad({ 'playlist:pl-key': 'on' });
        await loading;

        expect(module.getCollectionShufflePreference(ref)).toBeNull();
    });

    it('calls every listener even when an earlier one throws', async () => {
        (window as unknown as { go: unknown }).go = { server: { App: {
            GetCollectionShufflePreferences: vi.fn(async () => ({ 'album:album-key': 'on' })),
        } } };
        const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
        const module = await import('./collection-shuffle.js');
        const throwing = vi.fn(() => {
            throw new Error('listener failed');
        });
        const after = vi.fn();
        module.subscribeCollectionShufflePreferences(throwing);
        module.subscribeCollectionShufflePreferences(after);

        await module.loadCollectionShufflePreferences();

        expect(throwing).toHaveBeenCalledTimes(1);
        expect(after).toHaveBeenCalledTimes(1);
        expect(errorSpy).toHaveBeenCalled();
        errorSpy.mockRestore();
    });
});
