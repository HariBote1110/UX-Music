import { state, elements } from './state.js';
import {
    renderTrackView,
    renderAlbumView,
    renderArtistView,
    renderPlaylistView,
    renderAlbumDetailView,
    renderArtistDetailView,
    renderPlaylistDetailView,
    renderSituationView,
    clearMainContent
} from '../ui/view-renderer.js';
import { stopQuiz } from '../features/quiz.js';
import { stopLrcEditing } from '../features/lrc-editor.js';
import { startCDRipView, stopCDRipView } from '../features/cd-ripper.js';
import { initMtpBrowser, stopMtpBrowser } from '../features/mtp-browser.js';
import { musicApi } from './bridge.js';
// ▲▲▲ 追加 ▲▲▲

/**
 * 指定されたIDのビューを表示する
 * @param {string} viewId
 * @param {object} options
 */
export function showView(viewId, options = {}) {
    // ▼▼▼ 修正: 'cd-rip-view' と 'mtp-browser-view' を追加 ▼▼▼
    const isSpecialView = ['normalize-view', 'quiz-view', 'lrc-editor-view', 'cd-rip-view', 'mtp-browser-view'].includes(viewId);
    // ▲▲▲ 修正 ▲▲▲

    if (viewId !== 'quiz-view') stopQuiz();
    if (viewId !== 'lrc-editor-view') stopLrcEditing();
    // ▼▼▼ 追加 ▼▼▼
    if (viewId !== 'cd-rip-view') stopCDRipView();
    if (viewId !== 'mtp-browser-view') stopMtpBrowser();
    // ▲▲▲ 追加 ▲▲▲


    // Update nav link styles
    state.activeViewId = viewId;
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const mainViewLink = document.querySelector(`.nav-link[data-view="${viewId}"]`);
    if (mainViewLink && !isSpecialView) {
        mainViewLink.classList.add('active');
        state.activeListView = viewId;
        state.currentDetailView = { type: null, identifier: null };
    } else if (!isSpecialView) {
        state.currentDetailView = { type: options.type, identifier: options.identifier, data: options.data };
        const correspondingListViewLink = document.querySelector(`.nav-link[data-view="${options.type}-view"]`);
        if (correspondingListViewLink) {
            correspondingListViewLink.classList.add('active');
        }
    } else {
        state.currentDetailView = { type: null, identifier: null };
        const lastListViewLink = document.querySelector(`.nav-link[data-view="${state.activeListView}"]`);
        if (lastListViewLink) lastListViewLink.classList.add('active');
    }


    // Hide all containers and render the correct one
    elements.normalizeView.classList.add('hidden');
    const quizView = document.getElementById('quiz-view');
    if (quizView) quizView.classList.add('hidden');
    const lrcEditorView = document.getElementById('lrc-editor-view');
    if (lrcEditorView) lrcEditorView.classList.add('hidden');
    // ▼▼▼ 追加 ▼▼▼
    const cdRipView = document.getElementById('cd-rip-view');
    if (cdRipView) cdRipView.classList.add('hidden');
    const mtpBrowserView = document.getElementById('mtp-browser-view');
    if (mtpBrowserView) mtpBrowserView.classList.add('hidden');
    // ▲▲▲ 追加 ▲▲▲


    if (isSpecialView) {
        elements.mainContent.classList.add('hidden');
        clearMainContent();

        if (viewId === 'quiz-view' && quizView) {
            quizView.classList.remove('hidden');
        } else if (viewId === 'normalize-view') {
            elements.normalizeView.classList.remove('hidden');
        } else if (viewId === 'lrc-editor-view' && lrcEditorView) {
            lrcEditorView.classList.remove('hidden');
            // ▼▼▼ 追加 ▼▼▼
        } else if (viewId === 'cd-rip-view' && cdRipView) {
            cdRipView.classList.remove('hidden');
            startCDRipView();
        } else if (viewId === 'mtp-browser-view' && mtpBrowserView) {
            mtpBrowserView.classList.remove('hidden');
            initMtpBrowser(options.storageId, options.initialPath || '/');
        }
        // ▲▲▲ 追加 ▲▲▲
    } else {
        elements.mainContent.classList.remove('hidden');

        if (viewId === 'track-view') renderTrackView();
        else if (viewId === 'album-view') renderAlbumView();
        else if (viewId === 'artist-view') renderArtistView();
        else if (viewId === 'situation-view') renderSituationView();
        else if (viewId === 'playlist-view') renderPlaylistView();
        else if (viewId === 'album-detail-view') renderAlbumDetailView(options.data);
        else if (viewId === 'artist-detail-view') renderArtistDetailView(options.data);
        else if (viewId === 'playlist-detail-view') renderPlaylistDetailView(options.data);
    }
}


export function initNavigation() {
    elements.navLinks.forEach(link => {
        // mtp-device-nav-linkはipc.jsで別途ハンドルするため除外
        if (link.id === 'mtp-device-nav-link') return;

        link.addEventListener('click', (e) => {
            e.preventDefault();
            const viewId = link.dataset.view;
            showView(viewId);
        });
    });
}

export function showSituationPlaylistDetail(playlistDetails) {
    state.currentlyViewedSongIds = (playlistDetails.songs || []).map((song) => song.id).filter(Boolean);
    showView('playlist-detail-view', { type: 'situation', identifier: playlistDetails.name, data: playlistDetails });
}

export async function showPlaylist(playlistName) {
    try {
        const playlistDetails = await musicApi.getPlaylistDetails(playlistName);
        if (!playlistDetails) {
            console.error('[Navigation] Playlist details are null');
            return;
        }
        state.currentlyViewedSongIds = (playlistDetails.songs || []).map((song) => song.id).filter(Boolean);
        showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: playlistDetails });
    } catch (error) {
        console.error(`[Navigation] Failed to show playlist: ${playlistName}`, error);
    }
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;
    state.currentlyViewedSongIds = Array.from(album.songIds || []);
    showView('album-detail-view', { type: 'album', identifier: albumKey, data: album });
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;
    state.currentlyViewedSongIds = Array.from(artist.songIds || []);
    showView('artist-detail-view', { type: 'artist', identifier: artistName, data: artist });
}
