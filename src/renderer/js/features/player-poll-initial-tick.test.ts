import { beforeAll, afterEach, describe, expect, it, vi } from 'vitest';

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

afterEach(() => {
    delete (window as unknown as { go?: unknown }).go;
    vi.useRealTimers();
    vi.resetModules();
});

// park からの復帰直後、WebView 再生成で goState がゼロ初期化される一方 Go
// 側は再生を継続しているため、最初のポーリング tick が goPollDelayMs()
// (最大1000ms) 待ってから発火すると、その間 togglePlayPause/seek が
// stale な goState.isPlaying=false / duration=0 を読んでしまう
// （park-resume-cold-state.md 参照）。最初の tick は遅延なしで発火すべき。
describe('startGoStatePolling initial tick', () => {
    it('fires the first Go status poll immediately, without waiting goPollDelayMs()', async () => {
        vi.useFakeTimers();
        const AudioGetStatus = vi.fn().mockResolvedValue({ position: 12, duration: 200, playing: true, paused: false });
        (window as unknown as { go: unknown }).go = {
            server: { App: { AudioGetStatus } },
        };

        const { startGoStatePolling } = await import('./player.js');
        startGoStatePolling();

        // Flush microtasks without advancing any fake timer.
        await vi.advanceTimersByTimeAsync(0);

        expect(AudioGetStatus).toHaveBeenCalledTimes(1);
    });
});
