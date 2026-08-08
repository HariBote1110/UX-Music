import { beforeAll, describe, expect, it, vi } from 'vitest';
import { buildSkipEvent } from './playback-skip.js';
import { resolveLocalPlaybackGain } from './playback-gain.js';

beforeAll(() => {
    // jsdom の本物の window を使い、Electron ブリッジだけを差し込む。
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
});

describe('resolveLocalPlaybackGain', () => {
    it('computes Wails playback gain even when forcePlay is enabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: -24,
            targetLoudness: -18,
            forcePlay: true
        });

        expect(result.shouldWaitForAnalysis).toBe(false);
        expect(result.gainLinear).toBeCloseTo(Math.pow(10, 6 / 20), 10);
    });

    it('waits for loudness analysis when the value is missing and forcePlay is disabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: null,
            targetLoudness: -18,
            forcePlay: false
        });

        expect(result.shouldWaitForAnalysis).toBe(true);
        expect(result.gainLinear).toBe(1);
    });

    it('does not wait for loudness analysis when the value is missing and forcePlay is enabled', () => {
        const result = resolveLocalPlaybackGain({
            savedLoudnessRaw: undefined,
            targetLoudness: -18,
            forcePlay: true
        });

        expect(result.shouldWaitForAnalysis).toBe(false);
        expect(result.gainLinear).toBe(1);
    });
});

describe('buildSkipEvent', () => {
    it('builds skip payload from backend playback time without requiring a media element', () => {
        const song = { id: 'song-1', title: 'Skip Me', duration: 200 };
        expect(buildSkipEvent({
            analysedQueueEnabled: true,
            currentSongIndex: 0,
            skippedSong: song,
            currentTime: 12.5,
            duration: 200,
        })).toEqual({ song, currentTime: 12.5 });
    });
});

describe('resolveRemotePlaybackDownload', () => {
    it('downloads a remote song and resolves the matching local song', async () => {
        const { resolveRemotePlaybackDownload } = await import('./playback-manager.js');
        const remoteSong = { id: 'remote-1', syncAvailability: 'remote', syncSourceDeviceId: 'dev_host', syncSourceTrackId: 'track-1' };
        const calls: string[] = [];
        const resolved = await resolveRemotePlaybackDownload(remoteSong, {
            downloadSyncTrack: async (deviceId, trackId) => {
                calls.push(`${deviceId}:${trackId}`);
                return { importedPaths: ['/Music/local.flac'] };
            },
            refreshLibrary: async () => {},
            findLocalSong: () => ({ id: 'local-1', syncAvailability: 'local', path: '/Music/local.flac' }),
            notifyProgress: () => {},
            clearProgress: () => {},
        });

        expect(calls).toEqual(['dev_host:track-1']);
        expect(resolved).toEqual({ id: 'local-1', syncAvailability: 'local', path: '/Music/local.flac' });
    });

    it('returns null and reports the failure reason when the remote download fails', async () => {
        const { resolveRemotePlaybackDownload } = await import('./playback-manager.js');
        const notifyError = vi.fn();
        const clearProgress = vi.fn();
        const findLocalSong = vi.fn(() => ({ path: '/Music/local.flac' }));

        const resolved = await resolveRemotePlaybackDownload({ syncAvailability: 'remote', syncSourceDeviceId: 'dev_host', syncSourceTrackId: 'track-1' }, {
            downloadSyncTrack: async () => { throw new Error('peer offline'); },
            refreshLibrary: async () => {},
            findLocalSong,
            notifyProgress: () => {},
            clearProgress,
            notifyError,
        });

        expect(resolved).toBeNull();
        // 失敗を握り潰すと利用者に何も伝わらないため、通知が呼ばれたこと自体を検証する。
        expect(notifyError).toHaveBeenCalledOnce();
        expect(notifyError.mock.calls[0][0]).toContain('peer offline');
        // 取得に失敗したので、ライブラリ解決も進捗クリアも到達してはいけない。
        expect(findLocalSong).not.toHaveBeenCalled();
        expect(clearProgress).not.toHaveBeenCalled();
    });

    it('reports an error and returns null when the remote song lacks source identifiers', async () => {
        const { resolveRemotePlaybackDownload } = await import('./playback-manager.js');
        const notifyError = vi.fn();
        const downloadSyncTrack = vi.fn();

        const resolved = await resolveRemotePlaybackDownload(
            { syncAvailability: 'remote', syncSourceDeviceId: '  ', syncSourceTrackId: 'track-1' },
            { downloadSyncTrack, notifyError },
        );

        expect(resolved).toBeNull();
        expect(downloadSyncTrack).not.toHaveBeenCalled();
        expect(notifyError).toHaveBeenCalledOnce();
        expect(notifyError.mock.calls[0][0]).toContain('取得元の曲情報が不足しています');
    });

    it('reports an error when the downloaded track cannot be found in the library', async () => {
        const { resolveRemotePlaybackDownload } = await import('./playback-manager.js');
        const notifyError = vi.fn();
        const clearProgress = vi.fn();

        const resolved = await resolveRemotePlaybackDownload(
            { syncAvailability: 'remote', syncSourceDeviceId: 'dev_host', syncSourceTrackId: 'track-1' },
            {
                downloadSyncTrack: async () => ({ importedPaths: [] }),
                refreshLibrary: async () => {},
                findLocalSong: () => null,
                notifyProgress: () => {},
                clearProgress,
                notifyError,
            },
        );

        expect(resolved).toBeNull();
        expect(notifyError).toHaveBeenCalledOnce();
        expect(notifyError.mock.calls[0][0]).toContain('ライブラリで見つけられませんでした');
        expect(clearProgress).not.toHaveBeenCalled();
    });
});

describe('remoteQueuePrefetchRefs', () => {
    it('builds refs for upcoming remote queue items only', async () => {
        const { remoteQueuePrefetchRefs } = await import('./playback-manager.js');
        expect(remoteQueuePrefetchRefs([
            { syncAvailability: 'local', path: '/Music/current.flac' },
            { syncAvailability: 'remote', syncSourceDeviceId: 'dev_host', syncSourceTrackId: 'remote-1' },
            { syncAvailability: 'local', path: '/Music/local.flac' },
            { syncAvailability: 'remote', syncSourceDeviceId: 'dev_host', syncSourceTrackId: 'remote-2' },
        ], 0, 1)).toEqual([
            { sourceDeviceId: 'dev_host', sourceTrackId: 'remote-1' },
        ]);
    });
});
