import { beforeAll, describe, expect, it } from 'vitest';

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

// Bug A: startGoStatePolling() の巻き戻り防止ガードが、曲送り（isPlaying が
// 途切れず、position が新曲の 0 付近にリセットされる）を巻き戻りと誤検知し、
// シークバーが前曲の位置に固定されてしまう問題（progress/... 参照）。
describe('shouldSuppressPollRewind', () => {
    it('suppresses a small out-of-order rewind while still playing (transient async reorder)', async () => {
        const { shouldSuppressPollRewind } = await import('./player.js');
        expect(shouldSuppressPollRewind({ playing: true, wasPlaying: true, recentSeek: false, prevPos: 42, pos: 41.5 })).toBe(true);
    });

    it('does not suppress when position drops to ~0 on automatic track advance', async () => {
        const { shouldSuppressPollRewind } = await import('./player.js');
        expect(shouldSuppressPollRewind({ playing: true, wasPlaying: true, recentSeek: false, prevPos: 180, pos: 0 })).toBe(false);
    });

    it('does not suppress right after an explicit seek', async () => {
        const { shouldSuppressPollRewind } = await import('./player.js');
        expect(shouldSuppressPollRewind({ playing: true, wasPlaying: true, recentSeek: true, prevPos: 42, pos: 5 })).toBe(false);
    });

    it('does not suppress when playback just started (wasPlaying false)', async () => {
        const { shouldSuppressPollRewind } = await import('./player.js');
        expect(shouldSuppressPollRewind({ playing: true, wasPlaying: false, recentSeek: false, prevPos: 0, pos: 0 })).toBe(false);
    });
});
