// @ts-nocheck
/**
 * Library indexing and album/artist grouping — pure state mutations on `state`.
 */

import { state } from './state.js';

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

export function getAlbumSongs(album) {
    if (!album) return [];
    return resolveSongsByIds(album.songIds || []);
}

export function getArtistSongs(artist) {
    if (!artist) return [];
    return resolveSongsByIds(artist.songIds || []);
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
    const songIds = existingAlbum?.songIds ? [...existingAlbum.songIds] : [];

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
        const firstSong = getSongById(songIds[0]);
        const firstAlbumKey = firstSong?.albumKey;
        const representativeAlbum = state.albums.get(firstAlbumKey);
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
    const songIds = existingArtist?.songIds ? [...existingArtist.songIds] : [];

    if (!songIds.includes(song.id)) {
        songIds.push(song.id);
    }

    const representativeAlbum = state.albums.get(song.albumKey);
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
