import { beforeAll, describe, expect, it, vi } from 'vitest';

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

// Bug C: handleQueuePlayEmbedEvent が playQueueEmbedItem/playEmbed の
// false 戻り値（DOM 未準備などによるマウント失敗）を無視し、Go 側は
// 再生中と思い込んだままレンダラーは何も再生していない状態になる問題。
describe('handleQueuePlayEmbedEvent mount-failure retry/recovery', () => {
    it('retries once after a transient mount failure and starts playback on the retry success', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const playEmbedItem = vi.fn()
            .mockResolvedValueOnce(false)
            .mockResolvedValueOnce(true);
        const playbackStarted = vi.fn();
        const sleep = vi.fn(async () => {});
        const resetGoState = vi.fn();
        const song = { id: 'yt1' };

        await handleQueuePlayEmbedEvent({ id: 'yt1', type: 'youtube', path: 'https://youtu.be/xyz' }, {
            findSong: () => song,
            playEmbedItem,
            playbackStarted,
            loadLyricsForSong: vi.fn(),
            sleep,
            resetGoState,
        });

        expect(playEmbedItem).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenCalledTimes(1);
        expect(playbackStarted).toHaveBeenCalledWith(song);
        expect(resetGoState).not.toHaveBeenCalled();
    });

    it('recovers Go-side playback state when the retry also fails', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const playEmbedItem = vi.fn(async () => false);
        const playbackStarted = vi.fn();
        const sleep = vi.fn(async () => {});
        const resetGoState = vi.fn();

        await handleQueuePlayEmbedEvent({ id: 'yt1', type: 'youtube', path: 'https://youtu.be/xyz' }, {
            findSong: () => ({ id: 'yt1' }),
            playEmbedItem,
            playbackStarted,
            loadLyricsForSong: vi.fn(),
            sleep,
            resetGoState,
        });

        expect(playEmbedItem).toHaveBeenCalledTimes(2);
        expect(playbackStarted).not.toHaveBeenCalled();
        expect(resetGoState).toHaveBeenCalledTimes(1);
    });
});
