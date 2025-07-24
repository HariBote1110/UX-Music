import { state, elements } from '../state.js'; // ★★★ 修正箇所 ★★★
import { showAlbum, showArtist, showPlaylist } from '../navigation.js'; // ★★★ 修正箇所 ★★★
import { createPlaylistArtwork } from './playlist-artwork.js';
import { showContextMenu, formatTime } from './utils.js';
import { playSong } from '../playback-manager.js';
const { ipcRenderer } = require('electron');

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
            <div class="song-play-count">${(state.playCounts[song.path] && state.playCounts[song.path].count) || 0}</div>
        `;
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song); 
        });
        elements.musicList.appendChild(songItem);
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
            <img src="${album.artwork || './assets/default_artwork.png'}" class="album-artwork" alt="${album.title}">
            <div class="album-title">${album.title || 'Unknown Album'}</div>
            <div class="album-artist">${album.artist || 'Unknown Artist'}</div>
        `;
        albumItem.addEventListener('click', () => showAlbum(key));
        elements.albumGrid.appendChild(albumItem);
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
            <img src="${artist.artwork || './assets/default_artwork.png'}" class="artist-artwork" alt="${artist.name}">
            <div class="artist-name">${artist.name}</div>
        `;
        artistItem.addEventListener('click', () => showArtist(artist.name));
        elements.artistGrid.appendChild(artistItem);
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
            <div class="playlist-title">${playlist.name}</div>
        `;
        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        createPlaylistArtwork(artworkContainer, playlist.artworks);
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
    });
}