import { beforeEach, describe, expect, it } from 'vitest';

import { state } from './state.js';
import { mergeSongsIntoLibrary } from './library-model.js';

beforeEach(() => {
    state.library = [];
    state.libraryById = new Map();
    state.libraryByPath = new Map();
    state.albums = new Map();
    state.artists = new Map();
});

describe('mergeSongsIntoLibrary', () => {
    it('replaces stale remote songs when a matching local song is loaded', () => {
        mergeSongsIntoLibrary([{
            id: 'remote-1',
            title: ' Same Song ',
            artist: 'Artist',
            album: 'Album',
            duration: 200.2,
            syncAvailability: 'remote',
            syncSourceDeviceId: 'dev_host',
            syncSourceTrackId: 'track-1',
        }]);

        mergeSongsIntoLibrary([{
            id: 'local-1',
            path: '/Music/Same Song.flac',
            title: 'same song',
            artist: 'artist',
            album: 'album',
            duration: 200.4,
            syncAvailability: 'local',
        }]);

        expect(state.library).toHaveLength(1);
        expect(state.library[0]).toMatchObject({
            id: 'local-1',
            path: '/Music/Same Song.flac',
            syncAvailability: 'local',
        });
        expect(state.libraryById.has('remote-1')).toBe(false);
        expect(state.libraryById.get('local-1')).toBe(state.library[0]);
        expect(state.libraryByPath.get('/Music/Same Song.flac')).toBe(state.library[0]);
    });
});
