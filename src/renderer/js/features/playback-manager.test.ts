import { beforeAll, describe, expect, it, vi } from 'vitest';
import { buildSkipEvent } from './playback-skip.js';
import { resolveLocalPlaybackGain } from './playback-gain.js';
import { state, PLAYBACK_MODES } from '../core/state.js';

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

describe('handleRemotePlaySongEvent', () => {
    it('resolves the song by id and plays it via the same path as a click', async () => {
        const { handleRemotePlaySongEvent } = await import('./playback-manager.js');
        const song = { id: 'trk-1', title: 'Remote Song' };
        const findSong = vi.fn(() => song);
        const playResolvedSong = vi.fn();
        const notifyNotFound = vi.fn();
        const markRemoteInitiated = vi.fn();

        handleRemotePlaySongEvent('trk-1', { findSong, notifyNotFound, playResolvedSong, markRemoteInitiated });

        expect(findSong).toHaveBeenCalledWith('trk-1');
        expect(playResolvedSong).toHaveBeenCalledWith(song);
        expect(notifyNotFound).not.toHaveBeenCalled();
    });

    it('marks the session remote-initiated before starting playback, so the desktop stays silent', async () => {
        const { handleRemotePlaySongEvent } = await import('./playback-manager.js');
        const song = { id: 'trk-1', title: 'Remote Song' };
        const findSong = vi.fn(() => song);
        const callOrder: string[] = [];
        const playResolvedSong = vi.fn(() => { callOrder.push('play'); });
        const notifyNotFound = vi.fn();
        const markRemoteInitiated = vi.fn(() => { callOrder.push('mark'); });

        handleRemotePlaySongEvent('trk-1', { findSong, notifyNotFound, playResolvedSong, markRemoteInitiated });

        expect(markRemoteInitiated).toHaveBeenCalledOnce();
        expect(callOrder).toEqual(['mark', 'play']);
    });

    it('shows the not-found notification when the song id is unknown', async () => {
        const { handleRemotePlaySongEvent } = await import('./playback-manager.js');
        const findSong = vi.fn(() => null);
        const playResolvedSong = vi.fn();
        const notifyNotFound = vi.fn();
        const markRemoteInitiated = vi.fn();

        handleRemotePlaySongEvent('missing-id', { findSong, notifyNotFound, playResolvedSong, markRemoteInitiated });

        expect(notifyNotFound).toHaveBeenCalledOnce();
        expect(playResolvedSong).not.toHaveBeenCalled();
        expect(markRemoteInitiated).not.toHaveBeenCalled();
    });

    it('ignores non-string or empty payloads without touching the library', async () => {
        const { handleRemotePlaySongEvent } = await import('./playback-manager.js');
        const findSong = vi.fn();
        const playResolvedSong = vi.fn();
        const notifyNotFound = vi.fn();
        const markRemoteInitiated = vi.fn();

        handleRemotePlaySongEvent(undefined, { findSong, notifyNotFound, playResolvedSong, markRemoteInitiated });
        handleRemotePlaySongEvent('   ', { findSong, notifyNotFound, playResolvedSong, markRemoteInitiated });

        expect(findSong).not.toHaveBeenCalled();
        expect(playResolvedSong).not.toHaveBeenCalled();
        expect(notifyNotFound).not.toHaveBeenCalled();
        expect(markRemoteInitiated).not.toHaveBeenCalled();
    });
});

describe('handleRemoteCommandEvent', () => {
    it('advances to the next song for action "next"', async () => {
        const { handleRemoteCommandEvent } = await import('./playback-manager.js');
        const playNext = vi.fn();
        const playPrev = vi.fn();

        handleRemoteCommandEvent('next', { playNext, playPrev });

        expect(playNext).toHaveBeenCalledOnce();
        expect(playPrev).not.toHaveBeenCalled();
    });

    it('goes back to the previous song for action "prev"', async () => {
        const { handleRemoteCommandEvent } = await import('./playback-manager.js');
        const playNext = vi.fn();
        const playPrev = vi.fn();

        handleRemoteCommandEvent('prev', { playNext, playPrev });

        expect(playPrev).toHaveBeenCalledOnce();
        expect(playNext).not.toHaveBeenCalled();
    });

    it('ignores unknown actions', async () => {
        const { handleRemoteCommandEvent } = await import('./playback-manager.js');
        const playNext = vi.fn();
        const playPrev = vi.fn();

        handleRemoteCommandEvent('unknown', { playNext, playPrev });

        expect(playNext).not.toHaveBeenCalled();
        expect(playPrev).not.toHaveBeenCalled();
    });
});

describe('handleRemoteEmbedCommandEvent', () => {
    it('plays when toggled while paused', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const playCurrent = vi.fn();
        const pauseCurrent = vi.fn();
        const isPlaying = vi.fn(() => false);

        handleRemoteEmbedCommandEvent({ action: 'toggle' }, { playCurrent, pauseCurrent, isPlaying });

        expect(playCurrent).toHaveBeenCalledOnce();
        expect(pauseCurrent).not.toHaveBeenCalled();
    });

    it('pauses when toggled while playing', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const playCurrent = vi.fn();
        const pauseCurrent = vi.fn();
        const isPlaying = vi.fn(() => true);

        handleRemoteEmbedCommandEvent({ action: 'toggle' }, { playCurrent, pauseCurrent, isPlaying });

        expect(pauseCurrent).toHaveBeenCalledOnce();
        expect(playCurrent).not.toHaveBeenCalled();
    });

    it('routes play/pause/stop to their respective embed-aware player functions', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const playCurrent = vi.fn();
        const pauseCurrent = vi.fn();
        const stop = vi.fn();

        handleRemoteEmbedCommandEvent({ action: 'play' }, { playCurrent, pauseCurrent, stop });
        handleRemoteEmbedCommandEvent({ action: 'pause' }, { playCurrent, pauseCurrent, stop });
        handleRemoteEmbedCommandEvent({ action: 'stop' }, { playCurrent, pauseCurrent, stop });

        expect(playCurrent).toHaveBeenCalledOnce();
        expect(pauseCurrent).toHaveBeenCalledOnce();
        expect(stop).toHaveBeenCalledOnce();
    });

    it('seeks to the numeric value carried by the payload', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const seek = vi.fn();

        handleRemoteEmbedCommandEvent({ action: 'seek', value: 42.5 }, { seek });

        expect(seek).toHaveBeenCalledWith(42.5);
    });

    it('ignores a seek payload with a non-numeric value', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const seek = vi.fn();

        handleRemoteEmbedCommandEvent({ action: 'seek', value: 'nope' }, { seek });

        expect(seek).not.toHaveBeenCalled();
    });

    it('ignores non-object or malformed payloads', async () => {
        const { handleRemoteEmbedCommandEvent } = await import('./playback-manager.js');
        const playCurrent = vi.fn();
        const pauseCurrent = vi.fn();
        const stop = vi.fn();
        const seek = vi.fn();

        handleRemoteEmbedCommandEvent(null, { playCurrent, pauseCurrent, stop, seek });
        handleRemoteEmbedCommandEvent(undefined, { playCurrent, pauseCurrent, stop, seek });
        handleRemoteEmbedCommandEvent('toggle', { playCurrent, pauseCurrent, stop, seek });

        expect(playCurrent).not.toHaveBeenCalled();
        expect(pauseCurrent).not.toHaveBeenCalled();
        expect(stop).not.toHaveBeenCalled();
        expect(seek).not.toHaveBeenCalled();
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

// --- Wails native queue cutover (markdown/background-native-queue-plan.md Phase 1) ---
//
// From this point, isWails === true stops mutating state.playbackQueue/
// currentSongIndex itself and instead drives server/app_queue.go's Go
// queue, mirroring its "queue-state-changed"/"queue-advanced"/
// "queue-play-embed" events back into the renderer. The non-Wails browser
// fallback (isWails === false, exercised above) is untouched.

describe('runPlaySongWorkWails', () => {
    it('calls QueueSet with the whole source list when starting a new queue', async () => {
        const { runPlaySongWorkWails } = await import('./playback-manager.js');
        const app = { QueueSet: vi.fn(async () => {}), QueueJump: vi.fn(async () => {}) };
        const sourceList = [{ id: 's1', path: '/a.flac' }, { id: 's2', path: '/b.flac' }];

        await runPlaySongWorkWails(1, sourceList, { getApp: () => app });

        expect(app.QueueSet).toHaveBeenCalledWith(sourceList, 1);
        expect(app.QueueJump).not.toHaveBeenCalled();
    });

    it('calls QueueJump when jumping within the existing queue (no source list)', async () => {
        const { runPlaySongWorkWails } = await import('./playback-manager.js');
        const app = { QueueSet: vi.fn(async () => {}), QueueJump: vi.fn(async () => {}) };
        state.playbackQueue = [{ id: 's1' }, { id: 's2' }, { id: 's3' }];

        await runPlaySongWorkWails(2, null, { getApp: () => app });

        expect(app.QueueJump).toHaveBeenCalledWith(2);
        expect(app.QueueSet).not.toHaveBeenCalled();
    });

    it('resolves a remote (UX Sync) song before handing it to QueueSet', async () => {
        const { runPlaySongWorkWails } = await import('./playback-manager.js');
        const app = { QueueSet: vi.fn(async () => {}), QueueJump: vi.fn(async () => {}) };
        const remoteSong = { id: 'r1', syncAvailability: 'remote' };
        const localSong = { id: 'r1', syncAvailability: 'local', path: '/local.flac' };
        const sourceList = [remoteSong];

        await runPlaySongWorkWails(0, sourceList, {
            getApp: () => app,
            canStartPlayback: () => false,
            resolveRemotePlaybackDownload: async () => localSong,
        });

        expect(app.QueueSet).toHaveBeenCalledWith([localSong], 0);
    });

    it('does nothing when the remote download fails to resolve', async () => {
        const { runPlaySongWorkWails } = await import('./playback-manager.js');
        const app = { QueueSet: vi.fn(async () => {}), QueueJump: vi.fn(async () => {}) };

        await runPlaySongWorkWails(0, [{ id: 'r1', syncAvailability: 'remote' }], {
            getApp: () => app,
            canStartPlayback: () => false,
            resolveRemotePlaybackDownload: async () => null,
        });

        expect(app.QueueSet).not.toHaveBeenCalled();
    });

    it('does nothing when there is no Wails app available', async () => {
        const { runPlaySongWorkWails } = await import('./playback-manager.js');
        const app = { QueueSet: vi.fn(async () => {}), QueueJump: vi.fn(async () => {}) };

        await runPlaySongWorkWails(0, [{ id: 's1' }], { getApp: () => null });

        expect(app.QueueSet).not.toHaveBeenCalled();
    });
});

describe('playNextSong / playPrevSong in Wails mode', () => {
    it('playNextSong calls QueueNext instead of mutating the JS queue', async () => {
        const bridge = await import('../core/bridge.js');
        const { playNextSong } = await import('./playback-manager.js');
        const app = { QueueNext: vi.fn(async () => {}) };
        vi.spyOn(bridge, 'isWailsMode').mockReturnValue(true);
        vi.spyOn(bridge, 'getWailsApp').mockReturnValue(app as any);

        state.playbackQueue = [];
        state.currentSongIndex = -1;

        playNextSong();

        expect(app.QueueNext).toHaveBeenCalledOnce();

        vi.restoreAllMocks();
    });

    it('playPrevSong calls QueuePrev instead of mutating the JS queue', async () => {
        const bridge = await import('../core/bridge.js');
        const { playPrevSong } = await import('./playback-manager.js');
        const app = { QueuePrev: vi.fn(async () => {}) };
        vi.spyOn(bridge, 'isWailsMode').mockReturnValue(true);
        vi.spyOn(bridge, 'getWailsApp').mockReturnValue(app as any);

        playPrevSong();

        expect(app.QueuePrev).toHaveBeenCalledOnce();

        vi.restoreAllMocks();
    });
});

describe('handleQueueStateChangedEvent', () => {
    it('mirrors the Go snapshot into playbackQueue/currentSongIndex/isShuffled/playbackMode', async () => {
        const { handleQueueStateChangedEvent } = await import('./playback-manager.js');
        const findSong = (id: string) => (id === 'a' ? { id: 'a', title: 'A' } : null);
        const updatePlayingIndicators = vi.fn();
        const renderQueueView = vi.fn();
        const updateNowPlayingView = vi.fn();
        const loadLyricsForSong = vi.fn();
        const prefetchUpcomingRemoteTracks = vi.fn();
        const updateShuffleLoopButtons = vi.fn();

        handleQueueStateChangedEvent({
            items: [
                { id: 'a', type: 'local', path: '/a.flac', title: 'A', artist: '', album: '', artworkId: '' },
                { id: 'b', type: 'local', path: '/b.flac', title: 'B', artist: '', album: '', artworkId: '' },
            ],
            index: 1,
            shuffled: true,
            loopMode: 'one',
            active: true,
        }, {
            findSong, updatePlayingIndicators, renderQueueView, updateNowPlayingView,
            loadLyricsForSong, prefetchUpcomingRemoteTracks, updateShuffleLoopButtons,
        });

        expect(state.playbackQueue).toEqual([
            { id: 'a', title: 'A' },
            { id: 'b', type: 'local', path: '/b.flac', title: 'B', artist: '', album: '' },
        ]);
        expect(state.currentSongIndex).toBe(1);
        expect(state.isShuffled).toBe(true);
        expect(state.playbackMode).toBe(PLAYBACK_MODES.LOOP_ONE);

        expect(updatePlayingIndicators).toHaveBeenCalledOnce();
        expect(renderQueueView).toHaveBeenCalledOnce();
        expect(updateShuffleLoopButtons).toHaveBeenCalledWith(true, PLAYBACK_MODES.LOOP_ONE);
        expect(updateNowPlayingView).toHaveBeenCalledWith(state.playbackQueue[1]);
        expect(loadLyricsForSong).toHaveBeenCalledWith(state.playbackQueue[1]);
        expect(prefetchUpcomingRemoteTracks).toHaveBeenCalledWith(1);
    });

    it('reflects an empty/inactive queue as no current song', async () => {
        const { handleQueueStateChangedEvent } = await import('./playback-manager.js');
        const updateNowPlayingView = vi.fn();

        handleQueueStateChangedEvent({ items: [], index: -1, shuffled: false, loopMode: 'off', active: false }, {
            findSong: () => null,
            updatePlayingIndicators: vi.fn(),
            renderQueueView: vi.fn(),
            updateNowPlayingView,
            loadLyricsForSong: vi.fn(),
            prefetchUpcomingRemoteTracks: vi.fn(),
            updateShuffleLoopButtons: vi.fn(),
        });

        expect(state.playbackQueue).toEqual([]);
        expect(state.currentSongIndex).toBe(-1);
        expect(updateNowPlayingView).toHaveBeenCalledWith(null);
    });
});

// Park/restore artwork bug (progress/webview-parking.md): initGoQueueBridge()
// calls QueueGetState() before renderer.ts's musicApi.loadLibrary() response
// has populated state.library, so hydrateQueueItem()'s findSong(id) misses
// and falls back to a minimal Song with no `artwork` field for every queue
// item that was already active in Go's queue (the normal park-restore case,
// where Go's queue survives the SPA reboot). refreshQueueDisplayFromGoState()
// is called again once the library has actually loaded, to re-hydrate those
// entries from the now-populated library.
describe('refreshQueueDisplayFromGoState', () => {
    it('does nothing outside Wails mode', async () => {
        const { refreshQueueDisplayFromGoState } = await import('./playback-manager.js');
        const apply = vi.fn();

        await refreshQueueDisplayFromGoState({ isWails: () => false, apply });

        expect(apply).not.toHaveBeenCalled();
    });

    it('does nothing when QueueGetState() yields no payload', async () => {
        const { refreshQueueDisplayFromGoState } = await import('./playback-manager.js');
        const app = { QueueGetState: vi.fn(async () => null) };
        const apply = vi.fn();

        await refreshQueueDisplayFromGoState({ isWails: () => true, getApp: () => app, apply });

        expect(app.QueueGetState).toHaveBeenCalledOnce();
        expect(apply).not.toHaveBeenCalled();
    });

    it('re-fetches QueueGetState() and re-applies it', async () => {
        const { refreshQueueDisplayFromGoState } = await import('./playback-manager.js');
        const payload = { items: [], index: -1, shuffled: false, loopMode: 'off', active: false };
        const app = { QueueGetState: vi.fn(async () => payload) };
        const apply = vi.fn();

        await refreshQueueDisplayFromGoState({ isWails: () => true, getApp: () => app, apply });

        expect(apply).toHaveBeenCalledWith(payload);
    });

    it('re-hydrates state.playbackQueue with full library data (including artwork) once the library has finished loading', async () => {
        const { refreshQueueDisplayFromGoState, handleQueueStateChangedEvent } = await import('./playback-manager.js');

        const payload = {
            items: [{ id: 'a', type: 'local', path: '/a.flac', title: 'A', artist: '', album: '', artworkId: 'hash1' }],
            index: 0, shuffled: false, loopMode: 'off', active: true,
        };
        const app = { QueueGetState: vi.fn(async () => payload) };
        const librarySong = { id: 'a', title: 'A', artwork: { full: 'a.webp', thumbnail: 'a_thumb.webp' } };

        await refreshQueueDisplayFromGoState({
            isWails: () => true,
            getApp: () => app,
            apply: (p) => handleQueueStateChangedEvent(p, {
                findSong: (id: string) => (id === 'a' ? librarySong : null),
                updatePlayingIndicators: vi.fn(),
                renderQueueView: vi.fn(),
                updateNowPlayingView: vi.fn(),
                loadLyricsForSong: vi.fn(),
                prefetchUpcomingRemoteTracks: vi.fn(),
                updateShuffleLoopButtons: vi.fn(),
            }),
        });

        expect(state.playbackQueue[0]).toBe(librarySong);
    });
});

describe('handleQueueAdvancedEvent', () => {
    it('calls songFinished for reason "finished" when analysed-queue scoring is enabled', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const song = { id: 'a', title: 'A' };
        const songFinished = vi.fn();
        const songSkipped = vi.fn();

        handleQueueAdvancedEvent({ previousId: 'a', reason: 'finished' }, {
            analysedQueueEnabled: true,
            findSong: () => song,
            songFinished,
            songSkipped,
            getCurrentTime: () => 0,
            getDuration: () => 0,
        });

        expect(songFinished).toHaveBeenCalledWith(song);
        expect(songSkipped).not.toHaveBeenCalled();
    });

    it('calls songSkipped for reason "user" when there was real mid-song progress', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const song = { id: 'a', title: 'A' };
        const songFinished = vi.fn();
        const songSkipped = vi.fn();

        handleQueueAdvancedEvent({ previousId: 'a', reason: 'user' }, {
            analysedQueueEnabled: true,
            findSong: () => song,
            songFinished,
            songSkipped,
            getCurrentTime: () => 42.5,
            getDuration: () => 200,
        });

        expect(songSkipped).toHaveBeenCalledWith({ song, currentTime: 42.5 });
        expect(songFinished).not.toHaveBeenCalled();
    });

    it('does not record a "user" skip with no real progress (e.g. instant skip)', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const songSkipped = vi.fn();

        handleQueueAdvancedEvent({ previousId: 'a', reason: 'user' }, {
            analysedQueueEnabled: true,
            findSong: () => ({ id: 'a' }),
            songFinished: vi.fn(),
            songSkipped,
            getCurrentTime: () => 0,
            getDuration: () => 0,
        });

        expect(songSkipped).not.toHaveBeenCalled();
    });

    it('does nothing when analysed-queue scoring is disabled', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const songFinished = vi.fn();
        const findSong = vi.fn();

        handleQueueAdvancedEvent({ previousId: 'a', reason: 'finished' }, {
            analysedQueueEnabled: false,
            findSong,
            songFinished,
            songSkipped: vi.fn(),
            getCurrentTime: () => 0,
            getDuration: () => 0,
        });

        expect(findSong).not.toHaveBeenCalled();
        expect(songFinished).not.toHaveBeenCalled();
    });

    it('does nothing when the previous song cannot be found in the library', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const songFinished = vi.fn();

        handleQueueAdvancedEvent({ previousId: 'missing', reason: 'finished' }, {
            analysedQueueEnabled: true,
            findSong: () => null,
            songFinished,
            songSkipped: vi.fn(),
            getCurrentTime: () => 0,
            getDuration: () => 0,
        });

        expect(songFinished).not.toHaveBeenCalled();
    });

    it('ignores malformed payloads', async () => {
        const { handleQueueAdvancedEvent } = await import('./playback-manager.js');
        const songFinished = vi.fn();
        const deps = { analysedQueueEnabled: true, findSong: vi.fn(), songFinished, songSkipped: vi.fn(), getCurrentTime: () => 0, getDuration: () => 0 };

        handleQueueAdvancedEvent(null, deps);
        handleQueueAdvancedEvent(undefined, deps);
        handleQueueAdvancedEvent({ previousId: '', reason: 'finished' }, deps);

        expect(songFinished).not.toHaveBeenCalled();
    });
});

describe('handleQueuePlayEmbedEvent', () => {
    it('plays the full library song when the embed item id is known', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const librarySong = { id: 'yt1', type: 'youtube', title: 'Known', sourceURL: 'https://youtu.be/xyz' };
        const playEmbedItem = vi.fn(async () => true);
        const playbackStarted = vi.fn();
        const loadLyricsForSong = vi.fn();

        await handleQueuePlayEmbedEvent({ id: 'yt1', type: 'youtube', path: 'https://youtu.be/xyz', title: 'Stub' }, {
            findSong: () => librarySong,
            playEmbedItem,
            playbackStarted,
            loadLyricsForSong,
        });

        expect(playEmbedItem).toHaveBeenCalledWith(librarySong);
        expect(loadLyricsForSong).toHaveBeenCalledWith(librarySong);
        expect(playbackStarted).toHaveBeenCalledWith(librarySong);
    });

    it('falls back to a reconstructed song when the item is not in the library', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const playEmbedItem = vi.fn(async () => true);

        await handleQueuePlayEmbedEvent(
            { id: 'yt2', type: 'youtube', path: 'https://youtu.be/abc', title: 'Fallback', artist: 'A', album: 'Al' },
            { findSong: () => null, playEmbedItem, playbackStarted: vi.fn(), loadLyricsForSong: vi.fn() },
        );

        expect(playEmbedItem).toHaveBeenCalledWith({
            id: 'yt2', type: 'youtube', path: 'https://youtu.be/abc', title: 'Fallback', artist: 'A', album: 'Al',
        });
    });

    it('does not count a play when the embed player failed to mount', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const playbackStarted = vi.fn();

        await handleQueuePlayEmbedEvent({ id: 'yt1', type: 'youtube', path: 'https://youtu.be/xyz' }, {
            findSong: () => ({ id: 'yt1' }),
            playEmbedItem: vi.fn(async () => false),
            playbackStarted,
            loadLyricsForSong: vi.fn(),
        });

        expect(playbackStarted).not.toHaveBeenCalled();
    });

    it('ignores a malformed payload', async () => {
        const { handleQueuePlayEmbedEvent } = await import('./playback-manager.js');
        const playEmbedItem = vi.fn();

        await handleQueuePlayEmbedEvent(null, { playEmbedItem });
        await handleQueuePlayEmbedEvent(undefined, { playEmbedItem });

        expect(playEmbedItem).not.toHaveBeenCalled();
    });
});
