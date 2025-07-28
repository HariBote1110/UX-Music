import { formatTime } from './utils.js';
import { state } from '../state.js';
import { createPlaylistArtwork } from './playlist-artwork.js';

// --- 非同期ヘルパー ---
let artworksDir = null;
async function resolveArtworkPath(artworkFileName, ipcRenderer) {
    if (!artworksDir) {
        artworksDir = await ipcRenderer.invoke('get-artworks-dir');
    }
    
    if (!artworkFileName) return './assets/default_artwork.png';
    if (artworkFileName.startsWith('data:image')) return artworkFileName;
    if (artworkFileName.startsWith('http')) return artworkFileName;
    
    return `file://${artworksDir}/${artworkFileName}`;
}


// --- DOM生成関数 ---

/**
 * 曲リストの1行を生成する
 * @param {object} song - 曲オブジェクト
 * @param {number} index - リスト内でのインデックス
 * @param {object} ipcRenderer - electronのipcRenderer
 * @returns {HTMLElement} - 生成されたsong-item要素
 */
export function createSongItem(song, index, ipcRenderer) {
    const songItem = document.createElement('div');
    songItem.className = 'song-item';

    songItem.innerHTML = `
        <div class="song-index">${index + 1}</div>
        <div class="song-title">
            <img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">
            <div class="marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.title}</span>
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
        <div class="song-play-count">${(state.playCounts[song.path] && state.playCounts[song.path].count) || 0}</div>
    `;

    const artworkImg = songItem.querySelector('.artwork-small');
    resolveArtworkPath(song.artwork, ipcRenderer).then(src => artworkImg.src = src);
    
    return songItem;
}

/**
 * 再生キューの1行を生成する
 * @param {object} song - 曲オブジェクト
 * @param {boolean} isPlaying - 現在再生中か
 * @param {object} ipcRenderer - electronのipcRenderer
 * @returns {HTMLElement} - 生成されたqueue-item要素
 */
export function createQueueItem(song, isPlaying, ipcRenderer) {
    const queueItem = document.createElement('div');
    queueItem.className = `queue-item ${isPlaying ? 'playing' : ''}`;
    queueItem.dataset.songPath = song.path;
    queueItem.draggable = true;

    queueItem.innerHTML = `
        <img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">
        <div class="queue-item-info">
            <div class="queue-item-title marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.title}</span>
                </div>
            </div>
            <div class="queue-item-artist marquee-wrapper">
                <div class="marquee-content">
                    <span>${song.artist}</span>
                </div>
            </div>
        </div>
    `;
    
    const artworkImg = queueItem.querySelector('.artwork-small');
    resolveArtworkPath(song.artwork, ipcRenderer).then(src => artworkImg.src = src);

    return queueItem;
}


/**
 * アルバムグリッドのタイルを生成する
 * @param {string} key - アルバムキー
 * @param {object} album - アルバムオブジェクト
 * @param {object} ipcRenderer - electronのipcRenderer
 * @returns {HTMLElement} - 生成されたalbum-grid-item要素
 */
export function createAlbumGridItem(key, album, ipcRenderer) {
    const albumItem = document.createElement('div');
    albumItem.className = 'album-grid-item';
    albumItem.innerHTML = `
        <img src="./assets/default_artwork.png" class="album-artwork" alt="${album.title}">
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
    
    const artworkImg = albumItem.querySelector('.album-artwork');
    resolveArtworkPath(album.artwork, ipcRenderer).then(src => artworkImg.src = src);

    return albumItem;
}

/**
 * アーティストグリッドのタイルを生成する
 * @param {object} artist - アーティストオブジェクト
 * @param {object} ipcRenderer - electronのipcRenderer
 * @returns {HTMLElement} - 生成されたartist-grid-item要素
 */
export function createArtistGridItem(artist, ipcRenderer) {
    const artistItem = document.createElement('div');
    artistItem.className = 'artist-grid-item';
    artistItem.innerHTML = `
        <img src="./assets/default_artwork.png" class="artist-artwork" alt="${artist.name}">
        <div class="artist-name marquee-wrapper">
            <div class="marquee-content">
                <span>${artist.name}</span>
            </div>
        </div>
    `;

    const artworkImg = artistItem.querySelector('.artist-artwork');
    resolveArtworkPath(artist.artwork, ipcRenderer).then(src => artworkImg.src = src);

    return artistItem;
}

/**
 * プレイリストグリッドのタイルを生成する
 * @param {object} playlist - プレイリストオブジェクト
 * @param {object} ipcRenderer - electronのipcRenderer
 * @returns {HTMLElement} - 生成されたplaylist-grid-item要素
 */
export function createPlaylistGridItem(playlist, ipcRenderer) {
    const playlistItem = document.createElement('div');
    playlistItem.className = 'playlist-grid-item';
    playlistItem.innerHTML = `
        <div class="playlist-artwork-container"></div>
        <div class="playlist-title marquee-wrapper">
            <div class="marquee-content">
                <span>${playlist.name}</span>
            </div>
        </div>
    `;
    const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
    
    const resolver = (fileName) => resolveArtworkPath(fileName, ipcRenderer);
    createPlaylistArtwork(artworkContainer, playlist.artworks, resolver);

    return playlistItem;
}