import { state, elements, PLAYBACK_MODES } from './state.js';
import { playSong } from './playback-manager.js';
const { ipcRenderer } = require('electron');

export function initUI() {
    // UI要素への参照を `elements` オブジェクトに設定 (state.jsで実行済み)
}

function getYoutubeVideoId(url) {
    const regExp = /^.*(https?:\/\/www.youtube.com\/watch\?v=|&v=)([^#&?]*).*/;
    const match = url.match(regExp);
    return (match && match[2].length === 11) ? match[2] : null;
}

export function updateNowPlayingView(song) {
    const previewContainer = document.getElementById('now-playing-artwork-container');
    const localPlayer = document.getElementById('main-player');
    const ytPlayerWrapper = document.getElementById('youtube-player-container');
    const hubLinkContainer = document.getElementById('hub-link-container');

    previewContainer.innerHTML = '';
    hubLinkContainer.innerHTML = '';
    previewContainer.classList.remove('video-mode');
    document.body.appendChild(localPlayer);
    document.body.appendChild(ytPlayerWrapper);
    localPlayer.style.display = 'none';

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);
    } else if (song.type === 'youtube') {
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
    } else if (song.type === 'local' && song.path && song.path.toLowerCase().endsWith('.mp4')) {
        previewContainer.classList.add('video-mode');
        localPlayer.style.display = 'block';
        previewContainer.appendChild(localPlayer);
    } else {
        const img = document.createElement('img');
        img.src = song.artwork || './assets/default_artwork.png';
        previewContainer.appendChild(img);
    }
    
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => {
            ipcRenderer.send('open-external-link', song.hubUrl);
        });
        hubLinkContainer.appendChild(hubButton);
    }

    if (song) {
        elements.nowPlayingTitle.textContent = song.title;
        elements.nowPlayingArtist.textContent = song.artist;
    } else {
        elements.nowPlayingTitle.textContent = '曲を選択してください';
        elements.nowPlayingArtist.textContent = '';
    }
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
        // ★★★ バグ修正: インデックスではなくパスで再生中の曲を判定 ★★★
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, state.library));
        const artworkSrc = song.artwork || './assets/default_artwork.png';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        `;
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song); 
        });
        elements.musicList.appendChild(songItem);
    });
}

export function renderAlbumView() { /* ... (変更なし) ... */ }
export function renderPlaylistView() { /* ... (変更なし) ... */ }

export function renderPlaylistDetailView(playlistName, songs) {
    const header = document.querySelector('#playlist-detail-view .playlist-detail-header');
    header.querySelector('#p-detail-title').textContent = playlistName;
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;
    const artworkContainer = header.querySelector('.playlist-art-collage');
    const artworks = songs.map(s => s.artwork).filter(Boolean);
    createPlaylistArtwork(artworkContainer, artworks);

    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, songs));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-playlist-song-context-menu', { playlistName, song });
        });
        const artworkSrc = song.artwork || '';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
        `;
        listElement.appendChild(songItem);
    });
}

function createPlaylistArtwork(container, artworks) { /* ... (変更なし) ... */ }
function formatTime(seconds) { /* ... (変更なし) ... */ }