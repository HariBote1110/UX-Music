import { beforeEach, describe, expect, it } from 'vitest';

import { state } from './state.js';
import { mergeSongsIntoLibrary, regroupLibraryCollections, getArtistAlbums } from './library-model.js';

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

describe('getArtistAlbums', () => {
    it('コンピレーションアルバム（代表アーティストが Various Artists）でも参加アーティストのアルバムとして返す', () => {
        mergeSongsIntoLibrary([
            { id: 's1', path: '/m/1.flac', title: 'Track 1', artist: 'Artist A', album: 'Compilation X' },
            { id: 's2', path: '/m/2.flac', title: 'Track 2', artist: 'Artist B', album: 'Compilation X' },
        ]);
        regroupLibraryCollections();

        // 前提の確認: アルバムの代表アーティストは Various Artists になる
        expect(state.albums.get('Compilation X')?.artist).toBe('Various Artists');

        const artistA = state.artists.get('Artist A');
        expect(artistA).toBeDefined();

        const albums = getArtistAlbums(artistA as Record<string, unknown>);
        expect(albums.map(([key]) => key)).toContain('Compilation X');
    });

    it('通常のアルバムは従来どおりアーティストのアルバムとして返す', () => {
        mergeSongsIntoLibrary([
            { id: 's1', path: '/m/1.flac', title: 'Track 1', artist: 'Solo Artist', album: 'Solo Album' },
        ]);
        regroupLibraryCollections();

        const artist = state.artists.get('Solo Artist');
        const albums = getArtistAlbums(artist as Record<string, unknown>);
        expect(albums.map(([key]) => key)).toEqual(['Solo Album']);
    });

    it('同じアルバムに複数曲が参加していてもアルバムは重複しない', () => {
        mergeSongsIntoLibrary([
            { id: 's1', path: '/m/1.flac', title: 'Track 1', artist: 'Artist A', album: 'Album Y' },
            { id: 's2', path: '/m/2.flac', title: 'Track 2', artist: 'Artist A', album: 'Album Y' },
        ]);
        regroupLibraryCollections();

        const artist = state.artists.get('Artist A');
        const albums = getArtistAlbums(artist as Record<string, unknown>);
        expect(albums.map(([key]) => key)).toEqual(['Album Y']);
    });
});
