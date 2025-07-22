import { state, elements } from '../state.js';
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './detail-view-renderer.js';
const { ipcRenderer } = require('electron');

export async function showPlaylist(playlistName) {
    const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
    
    state.originalQueueSource = [...songs];
    state.playbackQueue = state.isShuffled ? state.shuffledQueue : state.originalQueueSource;
    state.currentSongIndex = -1;
    
    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    document.getElementById('playlist-detail-view').classList.remove('hidden');

    renderPlaylistDetailView(playlistName, songs);
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;

    state.originalQueueSource = [...album.songs];
    state.playbackQueue = state.isShuffled ? state.shuffledQueue : state.originalQueueSource;
    state.currentSongIndex = -1;

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

    state.currentSongIndex = -1;

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const artistDetail = document.getElementById('artist-detail-view');
    artistDetail.classList.remove('hidden');
    artistDetail.dataset.artistName = artistName;

    renderArtistDetailView(artist);
}