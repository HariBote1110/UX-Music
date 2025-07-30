import { state, elements } from '../state.js';
import { playSong } from '../playback-manager.js';
import { formatTime } from './utils.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { showAlbum } from '../navigation.js';
import { createSongItem, createAlbumGridItem } from './element-factory.js';
const { ipcRenderer } = require('electron');

// ▼▼▼ 変更点：関数を同期的(sync)に書き換え ▼▼▼
function resolveArtworkPath(artwork, isThumbnail = false) {
    if (!state.artworksDir) {
        console.error("resolveArtworkPath called before state.artworksDir was set.");
        return './assets/default_artwork.png';
    }
    
    if (!artwork) return './assets/default_artwork.png';

    if (typeof artwork === 'string' && (artwork.startsWith('data:image') || artwork.startsWith('http'))) {
        return artwork;
    }
    
    if (typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        const fileName = isThumbnail ? artwork.thumbnail : artwork.full;
        const subDir = isThumbnail ? 'thumbnails' : '';
        return `file://${state.artworksDir}/${subDir ? `${subDir}/` : ''}${fileName}`;
    }

    if (typeof artwork === 'string') {
        return `file://${state.artworksDir}/${artwork}`;
    }

    return './assets/default_artwork.png';
}
// ▲▲▲ 変更点ここまで ▲▲▲

export function renderAlbumDetailView(album) {
    const view = elements.albumDetailView;
    const artImg = view.querySelector('#a-detail-art');
    artImg.classList.add('lazy-load');
    artImg.dataset.src = resolveArtworkPath(album.artwork, false);
    window.observeNewArtworks(view);
    
    view.querySelector('#a-detail-title').textContent = album.title;
    view.querySelector('#a-detail-artist').textContent = album.artist;
    const totalDuration = album.songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    view.querySelector('#a-detail-meta').textContent = `${album.songs.length} 曲, ${formatTime(totalDuration)}`;

    const listElement = view.querySelector('#a-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    album.songs.forEach((song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
        
        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
        }
        
        songItem.addEventListener('click', () => playSong(index, album.songs));
        
        listElement.appendChild(songItem);
    });
    window.observeNewArtworks(listElement);
}

export function renderArtistDetailView(artist) {
    const view = elements.artistDetailView;
    const artImg = view.querySelector('#artist-detail-art');
    artImg.classList.add('lazy-load');
    artImg.dataset.src = resolveArtworkPath(artist.artwork, false);
    window.observeNewArtworks(view);
    
    view.querySelector('#artist-detail-name').textContent = artist.name;

    const gridElement = elements.artistDetailAlbumGrid;
    gridElement.innerHTML = '';

    const artistAlbums = [...state.albums.entries()].filter(([key, album]) => {
        return album.artist === artist.name;
    });

    view.querySelector('#artist-detail-meta').textContent = `${artistAlbums.length}枚のアルバム, ${artist.songs.length}曲`;

    if (artistAlbums.length === 0) {
        gridElement.innerHTML = `<div class="placeholder">このアーティストのアルバムは見つかりません</div>`;
        return;
    }
    
    for (const [key, album] of artistAlbums) {
        const albumItem = createAlbumGridItem(key, album, ipcRenderer);
        albumItem.addEventListener('click', () => showAlbum(key));
        gridElement.appendChild(albumItem);
    }
    window.observeNewArtworks(gridElement);
}

export function renderPlaylistDetailView(playlistName, songs) {
    const view = document.getElementById('playlist-detail-view');
    const header = view.querySelector('.detail-header');
    header.querySelector('#p-detail-title').textContent = playlistName;
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;
    
    const artworkContainer = view.querySelector('.playlist-art-collage');
    if (artworkContainer) {
        const artworks = songs.map(s => {
            const album = state.albums.get(s.albumKey);
            return album ? album.artwork : null;
        }).filter(Boolean);
        const resolver = (fileName) => resolveArtworkPath(fileName, true);
        createPlaylistArtwork(artworkContainer, artworks, resolver);
        window.observeNewArtworks(artworkContainer);
    } else {
        console.error("Could not find '.playlist-art-collage' in playlist detail view.");
    }

    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    songs.forEach((song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
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
        
        listElement.appendChild(songItem);
    });
    window.observeNewArtworks(listElement);

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