/**
 * Library indexing and album/artist grouping — pure state mutations on `state`.
 */

import { state } from './state.js';
import type { Song } from '../../types/domain.js';

export function rebuildLibraryIndexes() {
    state.libraryById = new Map();
    state.libraryByPath = new Map();

    state.library.forEach((song) => {
        if (!song?.id && song?.path) {
            song.id = song.path;
        }
        if (song?.id) {
            state.libraryById.set(song.id, song);
        }
        if (song?.path) {
            state.libraryByPath.set(song.path, song);
        }
    });
}

export function mergeSongsIntoLibrary(songs: Song[] = []) {
    if (!Array.isArray(songs) || songs.length === 0) {
        return false;
    }

    if (state.libraryByPath.size === 0 || state.libraryById.size === 0) {
        rebuildLibraryIndexes();
    }

    let changed = false;
    for (const newSong of songs) {
        if (!newSong.id && newSong.path) {
            newSong.id = newSong.path;
        }

        const existingSong = findExistingLibrarySong(newSong);
        if (existingSong) {
            Object.assign(existingSong, newSong);
            if (newSong.syncAvailability === 'local') {
                delete existingSong.syncSourceDeviceId;
                delete existingSong.syncSourcePeerName;
                delete existingSong.syncSourceTrackId;
            }
            changed = true;
            continue;
        }

        state.library.push(newSong);
        changed = true;
    }

    rebuildLibraryIndexes();
    return changed;
}

function findExistingLibrarySong(newSong: Song) {
    if (newSong.path) {
        const byPath = state.libraryByPath.get(newSong.path);
        if (byPath) {
            return byPath;
        }
    }

    const newKey = librarySongMatchKey(newSong);
    if (!newKey) {
        return null;
    }
    return state.library.find(existingSong => librarySongMatchKey(existingSong) === newKey) || null;
}

function librarySongMatchKey(song: Song) {
    const explicitKey = normaliseSongText(song.syncMatchKey);
    if (explicitKey) {
        return `sync:${explicitKey}`;
    }

    let title = normaliseSongText(song.title);
    const artist = normaliseSongText(song.artist);
    const album = normaliseSongText(song.album);
    if (!artist && !album && !title) {
        title = normaliseSongText(songFileBaseName(song.path));
    }
    if (!artist && !album && !title) {
        return '';
    }
    return `meta:${artist}|${album}|${title}|${songDurationSeconds(song.duration)}`;
}

function normaliseSongText(value: unknown) {
    if (typeof value !== 'string') {
        return '';
    }
    return value.normalize('NFKC').trim().toLowerCase().replace(/\s+/g, ' ');
}

function songDurationSeconds(value: unknown) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? Math.round(numeric) : 0;
}

function songFileBaseName(path: unknown) {
    if (typeof path !== 'string') {
        return '';
    }
    const normalisedPath = path.replace(/\\/g, '/');
    return normalisedPath.split('/').pop() || '';
}

export function getSongById(songId) {
    return state.libraryById.get(songId) || null;
}

export function getSongByPath(songPath) {
    return state.libraryByPath.get(songPath) || null;
}

export function resolveSongsByIds(songIds = []) {
    return songIds
        .map((songId) => getSongById(songId))
        .filter(Boolean);
}

export function getAlbumSongs(album: Record<string, unknown>) {
    if (!album) return [];
    const songs = resolveSongsByIds((album.songIds as string[]) || []);
    const hasCustomOrder = songs.some(s => ((s as Record<string, unknown>).customOrder as number ?? 0) > 0);
    if (hasCustomOrder) {
        return songs.sort((a, b) => {
            const aOrder = (a as Record<string, unknown>).customOrder as number ?? 9999;
            const bOrder = (b as Record<string, unknown>).customOrder as number ?? 9999;
            return aOrder - bOrder;
        });
    }
    return songs.sort((a, b) => {
        const ar = a as Record<string, unknown>;
        const br = b as Record<string, unknown>;
        const disc = ((ar.discNumber as number) || 0) - ((br.discNumber as number) || 0);
        if (disc !== 0) return disc;
        return ((ar.trackNumber as number) || 0) - ((br.trackNumber as number) || 0);
    });
}

export function getArtistSongs(artist: Record<string, unknown>) {
    if (!artist) return [];
    return resolveSongsByIds((artist.songIds as string[]) || []);
}

/**
 * アーティストが参加しているアルバムを [albumKey, album] の配列で返す。
 * 代表アーティスト名の一致ではなく、所属曲の albumKey から辿ることで、
 * コンピレーションアルバム（代表: Various Artists）も漏れなく含める。
 */
export function getArtistAlbums(artist: Record<string, unknown>): Array<[string, Record<string, unknown>]> {
    const albumKeys = new Set<string>();
    getArtistSongs(artist).forEach((song) => {
        const albumKey = (song as Record<string, unknown>).albumKey;
        if (typeof albumKey === 'string' && state.albums.has(albumKey)) {
            albumKeys.add(albumKey);
        }
    });
    return [...albumKeys].map((key) => [key, state.albums.get(key) as Record<string, unknown>]);
}

export function setCurrentViewSongs(songs = []) {
    state.currentlyViewedSongIds = songs.map((song) => song.id).filter(Boolean);
}

function normaliseTagText(value, fallback = '') {
    if (typeof value !== 'string') {
        return fallback;
    }
    const trimmed = value.trim();
    return trimmed || fallback;
}

export function groupLibraryByAlbum(isMigration = false) {
    const tempAlbumGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);

    const albumMetaByTitle = new Map();
    localSongs.forEach(song => {
        const albumTitle = normaliseTagText(song.album, 'Unknown Album');
        if (!albumMetaByTitle.has(albumTitle)) {
            albumMetaByTitle.set(albumTitle, { albumArtists: new Set(), artists: new Set() });
        }

        const albumMeta = albumMetaByTitle.get(albumTitle);
        const albumArtistFromTag = normaliseTagText(song.albumartist);
        if (albumArtistFromTag) {
            albumMeta.albumArtists.add(albumArtistFromTag);
        }
        albumMeta.artists.add(normaliseTagText(song.artist, 'Unknown Artist'));
    });

    const resolveRepresentativeArtist = (albumTitle) => {
        const albumMeta = albumMetaByTitle.get(albumTitle);
        if (!albumMeta) {
            return 'Unknown Artist';
        }

        if (albumMeta.albumArtists.size === 1) {
            return [...albumMeta.albumArtists][0];
        }
        if (albumMeta.albumArtists.size > 1) {
            return 'Various Artists';
        }

        if (albumMeta.artists.size === 1) {
            return [...albumMeta.artists][0];
        }
        if (albumMeta.artists.size > 1) {
            return 'Various Artists';
        }

        return 'Unknown Artist';
    };

    localSongs.forEach(song => {
        const albumTitle = normaliseTagText(song.album, 'Unknown Album');
        const groupKey = albumTitle;

        if (!tempAlbumGroups.has(groupKey)) {
            tempAlbumGroups.set(groupKey, {
                title: albumTitle,
                artist: resolveRepresentativeArtist(albumTitle),
                songIds: [],
                artwork: null
            });
        }

        const albumGroup = tempAlbumGroups.get(groupKey);
        albumGroup.songIds.push(song.id);

        if (albumTitle !== 'Unknown Album' && !albumGroup.artwork && song.artwork) {
            albumGroup.artwork = song.artwork;
        }
    });

    const oldAlbums = new Map(state.albums);
    state.albums.clear();

    for (const [groupKey, albumData] of tempAlbumGroups.entries()) {
        const albumTitle = albumData.title;
        const albumKey = groupKey;
        resolveSongsByIds(albumData.songIds).forEach(song => {
            song.albumKey = albumKey;
        });

        let finalArtwork = albumData.artwork;
        if (!finalArtwork) {
            for (const oldAlbum of oldAlbums.values()) {
                if (oldAlbum.title === albumTitle && oldAlbum.artwork) {
                    finalArtwork = oldAlbum.artwork;
                    break;
                }
            }
        }

        state.albums.set(albumKey, {
            title: albumTitle,
            artist: albumData.artist,
            songIds: albumData.songIds,
            artwork: finalArtwork
        });
    }

    if (isMigration) {
        state.library.forEach(song => {
            delete song.artwork;
        });
    }
}

export function upsertAlbumForSong(song) {
    const albumTitle = normaliseTagText(song.album, 'Unknown Album');
    const albumKey = albumTitle;
    const existingAlbum = state.albums.get(albumKey);
    const songIds: string[] = existingAlbum?.songIds ? [...(existingAlbum.songIds as string[])] : [];

    if (!songIds.includes(song.id)) {
        songIds.push(song.id);
    }

    song.albumKey = albumKey;

    const albumArtist = normaliseTagText(song.albumartist);
    let artist = albumArtist || normaliseTagText(song.artist, 'Unknown Artist');
    if (existingAlbum?.artist && existingAlbum.artist !== artist) {
        artist = 'Various Artists';
    }

    state.albums.set(albumKey, {
        title: albumTitle,
        artist,
        songIds,
        artwork: existingAlbum?.artwork || song.artwork || null
    });
}

export function groupLibraryByArtist() {
    state.artists.clear();
    const tempArtistGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);
    localSongs.forEach(song => {
        const artistName = song.albumartist || song.artist || 'Unknown Artist';
        if (!tempArtistGroups.has(artistName)) {
            tempArtistGroups.set(artistName, []);
        }
        tempArtistGroups.get(artistName).push(song.id);
    });
    for (const [artistName, songIds] of tempArtistGroups.entries()) {
        const firstSong = getSongById(songIds[0] as string);
        const firstAlbumKey = firstSong?.albumKey as string | undefined;
        const representativeAlbum = firstAlbumKey ? state.albums.get(firstAlbumKey) : undefined;
        state.artists.set(artistName, {
            name: artistName,
            artwork: representativeAlbum?.artwork || null,
            songIds: songIds
        });
    }
}

export function upsertArtistForSong(song) {
    const artistName = song.albumartist || song.artist || 'Unknown Artist';
    const existingArtist = state.artists.get(artistName);
    const songIds: string[] = existingArtist?.songIds ? [...(existingArtist.songIds as string[])] : [];

    if (!songIds.includes(song.id)) {
        songIds.push(song.id);
    }

    const representativeAlbum = song.albumKey ? state.albums.get(song.albumKey as string) : undefined;
    state.artists.set(artistName, {
        name: artistName,
        artwork: existingArtist?.artwork || representativeAlbum?.artwork || null,
        songIds
    });
}

export function regroupLibraryCollections() {
    groupLibraryByAlbum(false);
    groupLibraryByArtist();
}
