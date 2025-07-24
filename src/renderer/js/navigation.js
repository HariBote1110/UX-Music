import { state, elements } from './state.js'; // ★★★ 修正箇所 ★★★
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './ui/detail-view-renderer.js';
const { ipcRenderer } = require('electron');

export function initNavigation(renderCallback) {
    elements.navLinks.forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            
            const viewId = link.dataset.view;

            // すべてのアクティブ状態を解除
            elements.navLinks.forEach(l => l.classList.remove('active'));
            elements.views.forEach(view => view.classList.add('hidden'));

            // クリックされたリンクと対応するビューをアクティブに
            link.classList.add('active');
            const targetView = document.getElementById(viewId);
            if (targetView) {
                targetView.classList.remove('hidden');
            }
            
            // stateをリセット
            state.currentDetailView = { type: null, identifier: null };

            renderCallback();
        });
    });
}


export async function showPlaylist(playlistName) {
    const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
    
    // UIの状態のみを更新
    state.currentlyViewedSongs = songs;
    state.currentDetailView = { type: 'playlist', identifier: playlistName };
    
    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    document.getElementById('playlist-detail-view').classList.remove('hidden');

    renderPlaylistDetailView(playlistName, songs);
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;

    // UIの状態のみを更新
    state.currentlyViewedSongs = album.songs;
    state.currentDetailView = { type: 'album', identifier: albumKey };

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const aDetail = document.getElementById('album-detail-view');
    aDetail.classList.remove('hidden');
    aDetail.dataset.albumKey = albumKey; 

    renderAlbumDetailView(album);
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;
    
    // UIの状態のみを更新
    state.currentlyViewedSongs = []; // アーティスト画面自体には曲リストはない
    state.currentDetailView = { type: 'artist', identifier: artistName };

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const artistDetail = document.getElementById('artist-detail-view');
    artistDetail.classList.remove('hidden');
    artistDetail.dataset.artistName = artistName;

    renderArtistDetailView(artist);
}