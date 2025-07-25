import { state, elements } from './state.js';
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './ui/detail-view-renderer.js';
const { ipcRenderer } = require('electron');

export function initNavigation(renderCallback) {
    elements.navLinks.forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            
            const viewId = link.dataset.view;
            state.activeListView = viewId; // ★★★ アクティブなリストビューを記憶 ★★★

            elements.navLinks.forEach(l => l.classList.remove('active'));
            elements.views.forEach(view => view.classList.add('hidden'));

            link.classList.add('active');
            const targetView = document.getElementById(viewId);
            if (targetView) {
                targetView.classList.remove('hidden');
                targetView.scrollTop = 0; // ★★★ スクロール位置をリセット ★★★
            }
            
            state.currentDetailView = { type: null, identifier: null };

            renderCallback();
        });
    });
}

export function showMainView(viewId) {
    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));

    const targetView = document.getElementById(viewId);
    const targetLink = document.querySelector(`.nav-link[data-view="${viewId}"]`);

    if (targetView) {
        targetView.classList.remove('hidden');
        targetView.scrollTop = 0;
    }
    if (targetLink) {
        targetLink.classList.add('active');
    }
    state.currentDetailView = { type: null, identifier: null };
}

export async function showPlaylist(playlistName) {
    const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
    
    state.currentlyViewedSongs = songs;
    state.currentDetailView = { type: 'playlist', identifier: playlistName };
    
    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const targetView = document.getElementById('playlist-detail-view');
    targetView.classList.remove('hidden');
    targetView.scrollTop = 0; // ★★★ スクロール位置をリセット ★★★

    renderPlaylistDetailView(playlistName, songs);
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;

    state.currentlyViewedSongs = album.songs;
    state.currentDetailView = { type: 'album', identifier: albumKey };

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const targetView = document.getElementById('album-detail-view');
    targetView.classList.remove('hidden');
    targetView.scrollTop = 0; // ★★★ スクロール位置をリセット ★★★
    targetView.dataset.albumKey = albumKey; 

    renderAlbumDetailView(album);
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;
    
    state.currentlyViewedSongs = [];
    state.currentDetailView = { type: 'artist', identifier: artistName };

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const targetView = document.getElementById('artist-detail-view');
    targetView.classList.remove('hidden');
    targetView.scrollTop = 0; // ★★★ スクロール位置をリセット ★★★
    targetView.dataset.artistName = artistName;

    renderArtistDetailView(artist);
}