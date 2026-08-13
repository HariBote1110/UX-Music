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
});

describe('reportEmbedPlaybackState', () => {
    it('forwards position/duration/playing to the Go ReportEmbedPlaybackState binding when running under Wails', async () => {
        const ReportEmbedPlaybackState = vi.fn().mockResolvedValue(undefined);
        (window as unknown as { go: unknown }).go = {
            server: { App: { ReportEmbedPlaybackState } },
        };

        const { reportEmbedPlaybackState } = await import('./player.js');
        reportEmbedPlaybackState(42.5, 210, true);

        expect(ReportEmbedPlaybackState).toHaveBeenCalledWith(42.5, 210, true);
    });

    it('does nothing when no Wails Go binding is present (Electron)', async () => {
        vi.resetModules();
        delete (window as unknown as { go?: unknown }).go;

        const { reportEmbedPlaybackState } = await import('./player.js');
        // Must not throw even without window.go.
        expect(() => reportEmbedPlaybackState(1, 2, true)).not.toThrow();
    });
});
