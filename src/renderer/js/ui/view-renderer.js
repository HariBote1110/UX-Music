import { state, elements } from '../state.js';
import { showAlbum, showArtist, showPlaylist } from '../navigation.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
// ▼▼▼ ここからが修正箇所です ▼▼▼
import { showContextMenu, formatTime, checkTextOverflow } from './utils.js';
// ▲▲▲ ここまでが修正箇所です ▲▲▲
import { playSong } from '../playback-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let artworksDir = null; 

async function resolveArtworkPath(artworkFileName) {
    if (!artworkFileName) return './assets/default_artwork.png';
    
    if (artworkFileName.startsWith('data:image')) return artworkFileName;
    if (artworkFileName.startsWith('http')) return artworkFileName;
    
    if (!artworksDir) {
        artworksDir = await ipcRenderer.invoke('get-artworks-dir');
    }
    return `file://${path.join(artworksDir, artworkFileName)}`;
}

export function renderTrackView() {
    elements.musicList.innerHTML = '';
    if (state.library.length === 0) {
        elements.musicList.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    state.library.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, state.library));
        
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist"><span>${song.artist}</span></div>
            <div class="song-album"><span>${song.album}</span></div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-play-count">${(state.playCounts[song.path] && state.playCounts[song.path].count) || 0}</div>
        `;

        const artworkImg = songItem.querySelector('.artwork-small');
        resolveArtworkPath(song.artwork).then(src => artworkImg.src = src);

        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song); 
        });
        elements.musicList.appendChild(songItem);
        
        // ▼▼▼ ここからが修正箇所です ▼▼▼
        checkTextOverflow(songItem.querySelector('.song-title'));
        checkTextOverflow(songItem.querySelector('.song-artist'));
        checkTextOverflow(songItem.querySelector('.song-album'));
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
    });
}

export function renderAlbumView() {
    elements.albumGrid.innerHTML = '';
    if (state.albums.size === 0) {
        elements.albumGrid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
        return;
    }
    for (const [key, album] of state.albums.entries()) {
        const albumItem = document.createElement('div');
        albumItem.className = 'album-grid-item';
        albumItem.innerHTML = `
            <img src="./assets/default_artwork.png" class="album-artwork" alt="${album.title}">
            <div class="album-title"><span>${album.title || 'Unknown Album'}</span></div>
            <div class="album-artist"><span>${album.artist || 'Unknown Artist'}</span></div>
        `;
        
        const artworkImg = albumItem.querySelector('.album-artwork');
        resolveArtworkPath(album.artwork).then(src => artworkImg.src = src);

        albumItem.addEventListener('click', () => showAlbum(key));
        elements.albumGrid.appendChild(albumItem);

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        checkTextOverflow(albumItem.querySelector('.album-title'));
        checkTextOverflow(albumItem.querySelector('.album-artist'));
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
    }
}

export function renderArtistView() {
    elements.artistGrid.innerHTML = '';
    if (state.artists.size === 0) {
        elements.artistGrid.innerHTML = '<div class="placeholder">ライブラリにアーティストが見つかりません</div>';
        return;
    }
    const sortedArtists = [...state.artists.values()].sort((a, b) => a.name.localeCompare(b.name));
    sortedArtists.forEach(artist => {
        const artistItem = document.createElement('div');
        artistItem.className = 'artist-grid-item';
        artistItem.innerHTML = `
            <img src="./assets/default_artwork.png" class="artist-artwork" alt="${artist.name}">
            <div class="artist-name"><span>${artist.name}</span></div>
        `;

        const artworkImg = artistItem.querySelector('.artist-artwork');
        resolveArtworkPath(artist.artwork).then(src => artworkImg.src = src);

        artistItem.addEventListener('click', () => showArtist(artist.name));
        elements.artistGrid.appendChild(artistItem);

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        checkTextOverflow(artistItem.querySelector('.artist-name'));
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
    });
}

export function renderPlaylistView() {
    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        return;
    }
    state.playlists.forEach(playlist => {
        const playlistItem = document.createElement('div');
        playlistItem.className = 'playlist-grid-item';
        playlistItem.innerHTML = `
            <div class="playlist-artwork-container"></div>
            <div class="playlist-title"><span>${playlist.name}</span></div>
        `;
        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        
        createPlaylistArtwork(artworkContainer, playlist.artworks, resolveArtworkPath);

        playlistItem.addEventListener('click', () => showPlaylist(playlist.name));
        
        playlistItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            showContextMenu(e.pageX, e.pageY, [
                {
                    label: '削除',
                    action: async () => {
                        const confirmed = confirm(`プレイリスト「${playlist.name}」を削除しますか？\nこの操作は元に戻せません。`);
                        if (confirmed) {
                            await ipcRenderer.invoke('delete-playlist', playlist.name);
                        }
                    }
                }
            ]);
        });
        elements.playlistGrid.appendChild(playlistItem);

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        checkTextOverflow(playlistItem.querySelector('.playlist-title'));
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
    });
}