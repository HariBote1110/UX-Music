// uxmusic/src/renderer/js/ui/element-factory.js

import { formatTime, checkTextOverflow, resolveArtworkPath, formatSongTitle } from './utils.js';
import { state } from '../state.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
const path = require('path');

export function createSongItem(song, index, ipcRenderer) {
    const songItem = document.createElement('div');
    songItem.className = 'song-item';
    songItem.dataset.songPath = song.path;

    const artworkHTML = state.isLightFlightMode ? '' : `<img src="./assets/default_artwork.png" class="artwork-small lazy-load" alt="artwork">`;

    songItem.innerHTML = `
        <div class="song-index">
            <span class="song-number">${index + 1}</span>
            <div class="playing-indicator">
                <div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div>
                <div class="playing-indicator-bar"></div>
            </div>
            <img src="./assets/icons/static-visualizer.svg" class="static-visualizer-img" alt="Playing">
            </div>
        <div class="song-title">
            ${artworkHTML}
            <div class="marquee-wrapper">
                <div class="marquee-content">
                    <span>${formatSongTitle(song.title)}</span>
                </div>
            </div>
        </div>
        <div class="song-artist">
            <div class="marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.artist}</span>
                </div>
            </div>
        </div>
        <div class="song-album">
            <div class="marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.album}</span>
                </div>
            </div>
        </div>
        <div class="song-duration">${formatTime(song.duration || 0)}</div>
        <div class="song-play-count">${(state.playCounts && state.playCounts[song.path] && state.playCounts[song.path].count) || 0}</div>
    `;

    if (!state.isLightFlightMode) {
        const artworkImg = songItem.querySelector('.artwork-small');
        const album = state.albums.get(song.albumKey);
        
        // ▼▼▼ この2行を変更 ▼▼▼
        // 楽曲自身のアートワーク (YouTubeなど) を優先し、なければアルバムのアートワークを使用
        const artwork = song.artwork || (album ? album.artwork : null);
        
        artworkImg.classList.add('lazy-load');
        artworkImg.dataset.src = resolveArtworkPath(artwork, true);
        artworkImg.onload = () => {
            window.artworkLoadTimes.push(performance.now());
        };
    }
    
    requestAnimationFrame(() => {
        songItem.querySelectorAll('.marquee-wrapper').forEach(checkTextOverflow);
    });
    
    return songItem;
}

export function createQueueItem(song, isPlaying, ipcRenderer) {
    const queueItem = document.createElement('div');
    queueItem.className = `queue-item ${isPlaying ? 'playing' : ''}`;
    queueItem.dataset.songPath = song.path;
    queueItem.draggable = true;
    
    const artworkHTML = state.isLightFlightMode ? '' : `<img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">`;

    queueItem.innerHTML = `
        ${artworkHTML}
        <div class="queue-item-info">
            <div class="queue-item-title marquee-wrapper">
                <div class="marquee-content">
                    <span>${formatSongTitle(song.title)}</span>
                </div>
            </div>
            <div class="queue-item-artist marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.artist}</span>
                </div>
            </div>
        </div>
    `;
    
    if (!state.isLightFlightMode) {
        const artworkImg = queueItem.querySelector('.artwork-small');
        const album = state.albums.get(song.albumKey);
        const artworkFromAlbum = album ? album.artwork : null;
        const artworkFromSong = song.artwork;
        let finalArtwork = artworkFromAlbum || artworkFromSong;
        if (song.album === 'Unknown Album') {
            finalArtwork = null;
        }
        artworkImg.src = resolveArtworkPath(finalArtwork, true);
        artworkImg.onload = () => window.artworkLoadTimes.push(performance.now());
    }

    return queueItem;
}


export function createAlbumGridItem(key, album, ipcRenderer) {
    const albumItem = document.createElement('div');
    albumItem.className = 'album-grid-item';
    
    const artworkHTML = state.isLightFlightMode ? '' : `<img src="./assets/default_artwork.png" class="album-artwork lazy-load" alt="${album.title}">`;
    
    albumItem.innerHTML = `
        ${artworkHTML}
        <div class="album-title marquee-wrapper">
            <div class="marquee-content">
                <span>${album.title || 'Unknown Album'}</span>
            </div>
        </div>
        <div class="album-artist marquee-wrapper">
            <div class="marquee-content">
                <span>${album.artist || 'Unknown Artist'}</span>
            </div>
        </div>
    `;
    
    if (!state.isLightFlightMode) {
        const artworkImg = queueItem.querySelector('.artwork-small');
        const album = state.albums.get(song.albumKey);

        // ▼▼▼ この2行を変更 ▼▼▼
        // 楽曲自身のアートワーク (YouTubeなど) を優先し、なければアルバムのアートワークを使用
        const finalArtwork = song.artwork || (album ? album.artwork : null);

        artworkImg.src = resolveArtworkPath(finalArtwork, true);
        artworkImg.onload = () => window.artworkLoadTimes.push(performance.now());
    }

    return albumItem;
}

export function createArtistGridItem(artist, ipcRenderer) {
    const artistItem = document.createElement('div');
    artistItem.className = 'artist-grid-item';
    
    const artworkHTML = state.isLightFlightMode ? '' : `<img src="./assets/default_artwork.png" class="artist-artwork lazy-load" alt="${artist.name}">`;

    artistItem.innerHTML = `
        ${artworkHTML}
        <div class="artist-name marquee-wrapper">
            <div class="marquee-content">
                <span>${artist.name}</span>
            </div>
        </div>
    `;

    if (!state.isLightFlightMode) {
        const artworkImg = artistItem.querySelector('.artist-artwork');
        artworkImg.classList.add('lazy-load');
        artworkImg.dataset.src = resolveArtworkPath(artist.artwork, true);
        artworkImg.onload = () => window.artworkLoadTimes.push(performance.now());
    }

    return artistItem;
}

export function createPlaylistGridItem(playlist, ipcRenderer) {
    const playlistItem = document.createElement('div');
    playlistItem.className = 'playlist-grid-item';
    
    const artworkHTML = state.isLightFlightMode ? '' : `<div class="playlist-artwork-container"></div>`;
    
    playlistItem.innerHTML = `
        ${artworkHTML}
        <div class="playlist-title marquee-wrapper">
            <div class="marquee-content">
                <span>${playlist.name}</span>
            </div>
        </div>
    `;
    
    if (!state.isLightFlightMode) {
        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        const resolver = (artwork) => resolveArtworkPath(artwork, true);
        createPlaylistArtwork(artworkContainer, playlist.artworks, resolver);
    }

    return playlistItem;
}