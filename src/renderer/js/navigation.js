import { state, elements } from './state.js';
import { renderTrackView, renderAlbumView, renderArtistView, renderPlaylistView, renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView, renderSituationView } from './ui/view-renderer.js';
const { ipcRenderer } = require('electron');

/**
 * 指定されたIDのビューを表示する
 * @param {string} viewId 
 * @param {object} options 
 */
export function showView(viewId, options = {}) {
    state.activeViewId = viewId;
    elements.navLinks.forEach(l => l.classList.remove('active'));

    const mainViewLink = document.querySelector(`.nav-link[data-view="${viewId}"]`);
    if (mainViewLink) {
        mainViewLink.classList.add('active');
        state.activeListView = viewId;
        state.currentDetailView = { type: null, identifier: null };
    } else {
        state.currentDetailView = { type: options.type, identifier: options.identifier, data: options.data };
    }
    
    if (viewId === 'track-view') renderTrackView();
    else if (viewId === 'album-view') renderAlbumView();
    else if (viewId === 'artist-view') renderArtistView();
    else if (viewId === 'playlist-view') renderPlaylistView();
    else if (viewId === 'situation-view') renderSituationView();
    else if (viewId === 'album-detail-view') renderAlbumDetailView(options.data);
    else if (viewId === 'artist-detail-view') renderArtistDetailView(options.data);
    // ▼▼▼ 修正点 ▼▼▼
    else if (viewId === 'playlist-detail-view') renderPlaylistDetailView(options.data);
    // ▲▲▲ 修正点ここまで ▲▲▲
}

export function initNavigation() {
    elements.navLinks.forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            const viewId = link.dataset.view;
            showView(viewId);
        });
    });
}

// ▼▼▼ ここからが修正箇所です ▼▼▼
export async function showPlaylist(playlistName) {
    const playlistDetails = await ipcRenderer.invoke('get-playlist-details', playlistName);
    state.currentlyViewedSongs = playlistDetails.songs;
    showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: playlistDetails });
}
// ▲▲▲ ここまでが修正箇所です ▲▲▲

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;
    state.currentlyViewedSongs = album.songs;
    showView('album-detail-view', { type: 'album', identifier: albumKey, data: album });
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;
    state.currentlyViewedSongs = artist.songs;
    showView('artist-detail-view', { type: 'artist', identifier: artistName, data: artist });
}