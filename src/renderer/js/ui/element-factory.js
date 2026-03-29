// src/renderer/js/ui/element-factory.js
import { formatTime, checkTextOverflow, resolveArtworkPath, formatSongTitle, escapeHtml } from './utils.js';
import { state } from '../core/state.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { getVisibleColumns } from './column-config.js';

const pendingMarqueeWrappers = new Set();
let marqueeFlushFrameId = null;

function scheduleMarqueeMeasurement(songItem) {
    songItem.querySelectorAll('.marquee-wrapper').forEach((wrapper) => {
        pendingMarqueeWrappers.add(wrapper);
    });

    if (marqueeFlushFrameId) {
        return;
    }

    marqueeFlushFrameId = requestAnimationFrame(() => {
        pendingMarqueeWrappers.forEach((wrapper) => checkTextOverflow(wrapper));
        pendingMarqueeWrappers.clear();
        marqueeFlushFrameId = null;
    });
}

function findArtworkFromSongIds(songIds = []) {
    for (const songId of songIds) {
        const song = state.libraryById.get(songId);
        if (song?.artwork) {
            return song.artwork;
        }
    }
    return null;
}

export function createSongItem(song, index, songList, options = {}) {
    const { groupAlbumArt = false } = options;
    const songIdentifier = song.id || song.path || '';
    const songItem = document.createElement('div');
    songItem.className = 'song-item';
    songItem.dataset.songPath = song.path;
    songItem.dataset.songId = songIdentifier;

    let showArt = true;
    let isGrouped = false;
    let isLastOfGroup = false;

    if (groupAlbumArt && song.albumKey) {
        const prevSong = songList[index - 1];
        const isFirstOfGroup = !prevSong || prevSong.albumKey !== song.albumKey;
        if (!isFirstOfGroup) {
            const nextSong = songList[index + 1];
            isLastOfGroup = !nextSong || nextSong.albumKey !== song.albumKey;
            showArt = false;
            isGrouped = true;
        }
    }

    // Light Flightモードでもimgタグは常に生成し、CSSで表示を制御する
    const artworkHTML = `<img src="./assets/default_artwork.png" class="artwork-small lazy-load" alt="artwork">`;

    const hiResIconHTML = song.isHiRes ? `
        <svg class="hires-icon" width="24" height="14" viewBox="0 0 24 14" xmlns="http://www.w3.org/2000/svg">
            <rect x="0.5" y="0.5" width="23" height="13" rx="2" stroke="#D9A300" stroke-opacity="0.8" fill="none"/>
            <text x="12" y="10" font-family="Arial, sans-serif" font-size="9" font-weight="bold" fill="#D9A300" text-anchor="middle">HR</text>
        </svg>
    ` : '';

    // 可視列に基づいてHTMLを動的に構築
    const columnHTMLMap = {
        index: `<div class="song-index">
            <span class="song-number">${index + 1}</span>
            <div class="playing-indicator">
                <div class="playing-indicator-bar"></div><div class="playing-indicator-bar"></div><div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div><div class="playing-indicator-bar"></div><div class="playing-indicator-bar"></div>
            </div>
            <img src="./assets/icons/static-visualizer.svg" class="static-visualizer-img" alt="Playing">
        </div>`,
        artwork: `<div class="song-artwork-col">${artworkHTML}</div>`,
        title: `<div class="song-title"><div class="marquee-wrapper"><div class="marquee-content"><span>${escapeHtml(formatSongTitle(song.title))}</span></div></div></div>`,
        artist: `<div class="song-artist"><div class="marquee-wrapper"><div class="marquee-content"><span>${escapeHtml(song.artist)}</span></div></div></div>`,
        album: `<div class="song-album"><div class="marquee-wrapper"><div class="marquee-content"><span>${escapeHtml(song.album)}</span></div></div></div>`,
        hires: `<div class="song-hires">${hiResIconHTML}</div>`,
        duration: `<div class="song-duration"><span>${formatTime(song.duration || 0)}</span></div>`,
        playCount: `<div class="song-play-count">${(state.playCounts && state.playCounts[song.path] && state.playCounts[song.path].count) || 0}</div>`,
    };

    const visibleCols = getVisibleColumns();
    songItem.innerHTML = visibleCols.map(col => columnHTMLMap[col.key] || '').join('\n        ');

    const artworkCol = songItem.querySelector('.song-artwork-col');
    const artworkImg = songItem.querySelector('.artwork-small');

    if (isGrouped) {
        if (artworkImg) artworkImg.style.visibility = 'hidden';

        const verticalLine = document.createElement('div');
        verticalLine.style.position = 'absolute';
        verticalLine.style.left = '50%';
        verticalLine.style.width = '1px';
        verticalLine.style.backgroundColor = 'var(--text-muted)';
        verticalLine.style.transform = 'translateX(-50%)';

        if (isLastOfGroup) {
            verticalLine.style.top = '0';
            verticalLine.style.height = '50%';

            const horizontalLine = document.createElement('div');
            horizontalLine.style.position = 'absolute';
            horizontalLine.style.top = '50%';
            horizontalLine.style.left = '50%';
            horizontalLine.style.width = '50%';
            horizontalLine.style.height = '1px';
            horizontalLine.style.backgroundColor = 'var(--text-muted)';

            artworkCol.appendChild(horizontalLine);
        } else {
            verticalLine.style.top = '0';
            verticalLine.style.height = '100%';
        }
        artworkCol.appendChild(verticalLine);
    }

    if (artworkImg) {
        if (showArt) {
            const album = state.albums.get(song.albumKey);

            let artwork = null;
            if (song.album !== 'Unknown Album') {
                if (song.artwork) {
                    artwork = song.artwork;
                } else if (album) {
                    if (album.artwork) {
                        artwork = album.artwork;
                    } else {
                        artwork = findArtworkFromSongIds(album.songIds);
                    }
                }
            }

            artworkImg.classList.add('lazy-load');
            artworkImg.dataset.src = resolveArtworkPath(artwork, true);
        }
    }

    scheduleMarqueeMeasurement(songItem);

    return songItem;
}

export function createQueueItem(song, isPlaying, queueIndex) {
    const queueItem = document.createElement('div');
    queueItem.className = `queue-item ${isPlaying ? 'playing' : ''}`;
    queueItem.dataset.songPath = song.path;
    queueItem.dataset.queueIndex = String(queueIndex);
    queueItem.draggable = true;

    const artworkHTML = state.isLightFlightMode ? '' : `<img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">`;

    queueItem.innerHTML = `
        ${artworkHTML}
        <div class="queue-item-info">
            <div class="queue-item-title marquee-wrapper">
                <div class="marquee-content">
                    <span>${escapeHtml(formatSongTitle(song.title))}</span>
                </div>
            </div>
            <div class="queue-item-artist marquee-wrapper">
                <div class="marquee-content">
                    <span>${escapeHtml(song.artist)}</span>
                </div>
            </div>
        </div>
    `;

    if (!state.isLightFlightMode) {
        const artworkImg = queueItem.querySelector('.artwork-small');
        const album = state.albums.get(song.albumKey);

        let finalArtwork = song.artwork;
        if (!finalArtwork && song.album !== 'Unknown Album') {
            finalArtwork = album ? album.artwork : null;
        }

        artworkImg.src = resolveArtworkPath(finalArtwork, true);
        artworkImg.onload = () => window.recordArtworkLoadTime?.(performance.now());
    }

    return queueItem;
}


export function createAlbumGridItem(key, album) {
    const albumItem = document.createElement('div');
    albumItem.className = 'album-grid-item';

    const artworkHTML = state.isLightFlightMode ? '<div class="album-artwork placeholder-artwork"></div>' : `<img src="./assets/default_artwork.png" class="album-artwork lazy-load" alt="${escapeHtml(album.title)}">`;

    albumItem.innerHTML = `
        ${artworkHTML}
        <div class="album-title marquee-wrapper">
            <div class="marquee-content">
                <span>${escapeHtml(album.title || 'Unknown Album')}</span>
            </div>
        </div>
        <div class="album-artist marquee-wrapper">
            <div class="marquee-content">
                <span>${escapeHtml(album.artist || 'Unknown Artist')}</span>
            </div>
        </div>
    `;

    if (!state.isLightFlightMode) {
        const artworkImg = albumItem.querySelector('.album-artwork');
        artworkImg.classList.add('lazy-load');

        let artworkToUse = album.artwork;
        if (!artworkToUse) {
            artworkToUse = findArtworkFromSongIds(album?.songIds);
        }
        artworkImg.dataset.src = resolveArtworkPath(artworkToUse, false);

        artworkImg.onload = () => window.recordArtworkLoadTime?.(performance.now());
    }

    return albumItem;
}

export function createArtistGridItem(artist) {
    const artistItem = document.createElement('div');
    artistItem.className = 'artist-grid-item';

    const artworkHTML = state.isLightFlightMode ? '<div class="artist-artwork placeholder-artwork"></div>' : `<img src="./assets/default_artwork.png" class="artist-artwork lazy-load" alt="${escapeHtml(artist.name)}">`;

    artistItem.innerHTML = `
        ${artworkHTML}
        <div class="artist-name marquee-wrapper">
            <div class="marquee-content">
                <span>${escapeHtml(artist.name)}</span>
            </div>
        </div>
    `;

    if (!state.isLightFlightMode) {
        const artworkImg = artistItem.querySelector('.artist-artwork');
        artworkImg.classList.add('lazy-load');
        artworkImg.dataset.src = resolveArtworkPath(artist.artwork, false);
        artworkImg.onload = () => window.recordArtworkLoadTime?.(performance.now());
    }

    return artistItem;
}

export function createPlaylistGridItem(playlist) {
    const playlistItem = document.createElement('div');
    playlistItem.className = 'playlist-grid-item';

    const artworkHTML = state.isLightFlightMode ? '<div class="playlist-artwork-container placeholder-artwork"></div>' : `<div class="playlist-artwork-container"></div>`;

    playlistItem.innerHTML = `
        ${artworkHTML}
        <div class="playlist-title marquee-wrapper">
            <div class="marquee-content">
                <span>${escapeHtml(playlist.name)}</span>
            </div>
        </div>
    `;

    if (!state.isLightFlightMode) {
        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        const resolver = (artwork) => resolveArtworkPath(artwork, false);
        createPlaylistArtwork(artworkContainer, playlist.artworks, resolver);
    }

    return playlistItem;
}
