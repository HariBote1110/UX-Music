import { state, elements } from '../state.js';
import { playSong } from '../playback-manager.js';
import { formatTime } from './utils.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
const { ipcRenderer } = require('electron');

export function renderAlbumDetailView(album) {
    const view = elements.albumDetailView;
    view.querySelector('#a-detail-art').src = album.artwork || './assets/default_artwork.png';
    view.querySelector('#a-detail-title').textContent = album.title;
    view.querySelector('#a-detail-artist').textContent = album.artist;
    const totalDuration = album.songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    view.querySelector('#a-detail-meta').textContent = `${album.songs.length} 曲, ${formatTime(totalDuration)}`;

    const listElement = view.querySelector('#a-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    album.songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, album.songs));
        
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
        listElement.appendChild(songItem);
    });
}

export function renderArtistDetailView(artist) {
    const view = elements.artistDetailView;
    view.querySelector('#artist-detail-art').src = artist.artwork || './assets/default_artwork.png';
    view.querySelector('#artist-detail-name').textContent = artist.name;

    const gridElement = elements.artistDetailAlbumGrid;
    gridElement.innerHTML = '';

    const artistAlbums = [...state.albums.entries()].filter(([key, album]) => {
        return album.artist === artist.name || album.songs.some(song => song.artist === artist.name);
    });

    view.querySelector('#artist-detail-meta').textContent = `${artistAlbums.length}枚のアルバム, ${artist.songs.length}曲`;

    if (artistAlbums.length === 0) {
        gridElement.innerHTML = `<div class="placeholder">このアーティストのアルバムは見つかりません</div>`;
        return;
    }
    
    for (const [key, album] of artistAlbums) {
        const albumItem = document.createElement('div');
        albumItem.className = 'album-grid-item';
        albumItem.innerHTML = `
            <img src="${album.artwork || './assets/default_artwork.png'}" class="album-artwork" alt="${album.title}">
            <div class="album-title">${album.title || 'Unknown Album'}</div>
            <div class="album-artist">${album.artist || 'Unknown Artist'}</div>
        `;
        albumItem.addEventListener('click', () => showAlbum(key));
        gridElement.appendChild(albumItem);
    }
}

export function renderPlaylistDetailView(playlistName, songs) {
    const view = document.getElementById('playlist-detail-view');
    const header = view.querySelector('.detail-header');
    header.querySelector('#p-detail-title').textContent = playlistName;
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;
    
    const artworkContainer = view.querySelector('.playlist-art-collage');
    if (artworkContainer) {
        const artworks = songs.map(s => s.artwork).filter(Boolean);
        createPlaylistArtwork(artworkContainer, artworks);
    } else {
        console.error("Could not find '.playlist-art-collage' in playlist detail view.");
    }

    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        songItem.className = 'song-item';
        songItem.dataset.songPath = song.path;
        songItem.draggable = true;

        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
        }
        
        songItem.addEventListener('click', () => playSong(index, songs));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-playlist-song-context-menu', { playlistName, song });
        });
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
        listElement.appendChild(songItem);
    });

    let draggedItem = null;

    listElement.addEventListener('dragstart', e => {
        draggedItem = e.target.closest('.song-item');
        setTimeout(() => {
            if (draggedItem) draggedItem.classList.add('dragging');
        }, 0);
    });

    listElement.addEventListener('dragover', e => {
        e.preventDefault();
        const afterElement = getDragAfterElement(listElement, e.clientY);
        if (draggedItem) {
            if (afterElement == null) {
                listElement.appendChild(draggedItem);
            } else {
                listElement.insertBefore(draggedItem, afterElement);
            }
        }
    });

    listElement.addEventListener('dragend', async () => {
        if (draggedItem) {
            draggedItem.classList.remove('dragging');
            const newOrder = [...listElement.querySelectorAll('.song-item')].map(item => item.dataset.songPath);
            await ipcRenderer.invoke('update-playlist-song-order', { playlistName, newOrder });
            const newSongs = newOrder.map(path => songs.find(s => s.path === path));
            state.originalQueueSource = newSongs;
            renderPlaylistDetailView(playlistName, newSongs);
        }
        draggedItem = null;
    });

    function getDragAfterElement(container, y) {
        const draggableElements = [...container.querySelectorAll('.song-item:not(.dragging)')];
        return draggableElements.reduce((closest, child) => {
            const box = child.getBoundingClientRect();
            const offset = y - box.top - box.height / 2;
            if (offset < 0 && offset > closest.offset) {
                return { offset: offset, element: child };
            } else {
                return closest;
            }
        }, { offset: Number.NEGATIVE_INFINITY }).element;
    }
}