import { describe, expect, it, vi } from 'vitest';
import {
    fromGoLoopMode,
    hydrateQueueItem,
    mapQueueSnapshotToQueueState,
    nextLoopMode,
    shouldRecordQueueAdvancedSkip,
    toGoLoopMode,
} from './queue-bridge.js';
import { PLAYBACK_MODES } from '../core/state.js';

describe('toGoLoopMode / fromGoLoopMode', () => {
    it('maps every JS playback mode to its Go counterpart', () => {
        expect(toGoLoopMode(PLAYBACK_MODES.NORMAL)).toBe('off');
        expect(toGoLoopMode(PLAYBACK_MODES.LOOP_ALL)).toBe('all');
        expect(toGoLoopMode(PLAYBACK_MODES.LOOP_ONE)).toBe('one');
    });

    it('falls back to "off" for an unknown JS mode', () => {
        expect(toGoLoopMode('bogus')).toBe('off');
    });

    it('maps every Go loop mode back to its JS counterpart', () => {
        expect(fromGoLoopMode('off')).toBe(PLAYBACK_MODES.NORMAL);
        expect(fromGoLoopMode('all')).toBe(PLAYBACK_MODES.LOOP_ALL);
        expect(fromGoLoopMode('one')).toBe(PLAYBACK_MODES.LOOP_ONE);
    });

    it('falls back to NORMAL for an unknown/missing Go mode', () => {
        expect(fromGoLoopMode('bogus')).toBe(PLAYBACK_MODES.NORMAL);
        expect(fromGoLoopMode(undefined)).toBe(PLAYBACK_MODES.NORMAL);
    });
});

describe('nextLoopMode', () => {
    it('cycles normal -> loop-all -> loop-one -> normal', () => {
        expect(nextLoopMode(PLAYBACK_MODES.NORMAL)).toBe(PLAYBACK_MODES.LOOP_ALL);
        expect(nextLoopMode(PLAYBACK_MODES.LOOP_ALL)).toBe(PLAYBACK_MODES.LOOP_ONE);
        expect(nextLoopMode(PLAYBACK_MODES.LOOP_ONE)).toBe(PLAYBACK_MODES.NORMAL);
    });
});

describe('hydrateQueueItem', () => {
    it('prefers the full library song when found by id', () => {
        const librarySong = { id: 's1', title: 'Full', artist: 'A', artwork: { full: 'x.webp' } };
        const findSong = vi.fn(() => librarySong);
        const item = { id: 's1', type: 'local', path: '/music/s1.flac', title: 'Stub', artist: '', album: '', artworkId: '' };

        expect(hydrateQueueItem(item, findSong)).toBe(librarySong);
        expect(findSong).toHaveBeenCalledWith('s1');
    });

    it('falls back to a reconstructed song from the queue item when not in the library', () => {
        const findSong = vi.fn(() => null);
        const item = { id: 'yt1', type: 'youtube', path: 'https://youtu.be/xyz', title: 'YT Song', artist: 'Artist', album: 'Album', artworkId: '' };

        expect(hydrateQueueItem(item, findSong)).toEqual({
            id: 'yt1',
            type: 'youtube',
            path: 'https://youtu.be/xyz',
            title: 'YT Song',
            artist: 'Artist',
            album: 'Album',
        });
    });
});

describe('mapQueueSnapshotToQueueState', () => {
    it('hydrates items and carries index/shuffled/loopMode through', () => {
        const findSong = (id: string) => (id === 'a' ? { id: 'a', title: 'A' } : null);
        const result = mapQueueSnapshotToQueueState({
            items: [
                { id: 'a', type: 'local', path: '/a.flac', title: 'A', artist: '', album: '', artworkId: '' },
                { id: 'b', type: 'local', path: '/b.flac', title: 'B', artist: '', album: '', artworkId: '' },
            ],
            index: 1,
            shuffled: true,
            loopMode: 'all',
            active: true,
        }, findSong);

        expect(result.playbackQueue).toEqual([
            { id: 'a', title: 'A' },
            { id: 'b', type: 'local', path: '/b.flac', title: 'B', artist: '', album: '' },
        ]);
        expect(result.currentSongIndex).toBe(1);
        expect(result.isShuffled).toBe(true);
        expect(result.playbackMode).toBe(PLAYBACK_MODES.LOOP_ALL);
    });

    it('degrades gracefully on a malformed/missing payload', () => {
        const findSong = () => null;
        expect(mapQueueSnapshotToQueueState(null, findSong)).toEqual({
            playbackQueue: [],
            currentSongIndex: -1,
            isShuffled: false,
            playbackMode: PLAYBACK_MODES.NORMAL,
        });
        expect(mapQueueSnapshotToQueueState({}, findSong)).toEqual({
            playbackQueue: [],
            currentSongIndex: -1,
            isShuffled: false,
            playbackMode: PLAYBACK_MODES.NORMAL,
        });
    });
});

describe('shouldRecordQueueAdvancedSkip', () => {
    it('requires both a positive current time and a positive duration', () => {
        expect(shouldRecordQueueAdvancedSkip(12.5, 200)).toBe(true);
        expect(shouldRecordQueueAdvancedSkip(0, 200)).toBe(false);
        expect(shouldRecordQueueAdvancedSkip(12.5, 0)).toBe(false);
        expect(shouldRecordQueueAdvancedSkip(-1, 200)).toBe(false);
    });
});
