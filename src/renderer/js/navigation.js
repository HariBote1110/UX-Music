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
} from './ui/view-renderer.js';
// --- ▼▼▼ 追加 ▼▼▼ ---
import { stopQuiz } from './quiz.js'; // クイズ終了処理をインポート
import { stopLrcEditing } from './lrc-editor.js'; // LRCエディタ終了処理をインポート(後で作成)
// --- ▲▲▲ 追加 ▲▲▲ ---
const { ipcRenderer } = require('electron');

/**
 * 指定されたIDのビューを表示する
 * @param {string} viewId
 * @param {object} options
 */
export function showView(viewId, options = {}) {
    // --- ▼▼▼ 修正: lrc-editor-view を特別ビューに追加 ▼▼▼ ---
    const isSpecialView = ['normalize-view', 'quiz-view', 'lrc-editor-view'].includes(viewId);
    // --- ▲▲▲ 修正 ▲▲▲ ---

    // --- ▼▼▼ 修正: 他の特別ビューに切り替える際に既存の特別ビューを停止 ▼▼▼ ---
    if (viewId !== 'quiz-view') stopQuiz();
    if (viewId !== 'lrc-editor-view') stopLrcEditing(); // 編集状態をリセットする関数を呼ぶ
    // --- ▲▲▲ 修正 ▲▲▲ ---


    // Update nav link styles
    state.activeViewId = viewId;
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const mainViewLink = document.querySelector(`.nav-link[data-view="${viewId}"]`);
    if (mainViewLink && !isSpecialView) { // 通常ビューのリンクの場合
        mainViewLink.classList.add('active');
        state.activeListView = viewId; // 最後に表示したリストビューを記憶
        state.currentDetailView = { type: null, identifier: null };
    } else if (!isSpecialView) { // 詳細ビューの場合
        state.currentDetailView = { type: options.type, identifier: options.identifier, data: options.data };
        // 対応するリストビューのリンクをアクティブにする (例: アルバム詳細ならアルバムリンク)
        const correspondingListViewLink = document.querySelector(`.nav-link[data-view="${options.type}-view"]`);
        if (correspondingListViewLink) {
             correspondingListViewLink.classList.add('active');
        }
    } else {
         // 特別ビューの場合は currentDetailView はリセット、activeListView は維持
         state.currentDetailView = { type: null, identifier: null };
         // 最後に表示していたリストビューのリンクをアクティブにする
         const lastListViewLink = document.querySelector(`.nav-link[data-view="${state.activeListView}"]`);
         if(lastListViewLink) lastListViewLink.classList.add('active');
    }


    // Hide all containers and render the correct one
    elements.normalizeView.classList.add('hidden');
    const quizView = document.getElementById('quiz-view');
    if (quizView) quizView.classList.add('hidden');
    // --- ▼▼▼ 追加 ▼▼▼ ---
    const lrcEditorView = document.getElementById('lrc-editor-view');
    if (lrcEditorView) lrcEditorView.classList.add('hidden');
    // --- ▲▲▲ 追加 ▲▲▲ ---


    if (isSpecialView) {
        elements.mainContent.classList.add('hidden');
        clearMainContent(); // Clean up main content when switching away from it

        if (viewId === 'quiz-view' && quizView) {
            quizView.classList.remove('hidden');
        } else if (viewId === 'normalize-view') {
            elements.normalizeView.classList.remove('hidden');
        // --- ▼▼▼ 追加 ▼▼▼ ---
        } else if (viewId === 'lrc-editor-view' && lrcEditorView) {
            lrcEditorView.classList.remove('hidden');
        // --- ▲▲▲ 追加 ▲▲▲ ---
        }
    } else {
        elements.mainContent.classList.remove('hidden');

        // Render functions will handle clearing and drawing content
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


// ... (initNavigation, showSituationPlaylistDetail, showPlaylist, showAlbum, showArtist は変更なし) ...
export function initNavigation() {
    elements.navLinks.forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            const viewId = link.dataset.view;
            showView(viewId);
        });
    });
}

/**
 * シチュエーションプレイリストの詳細画面を表示する
 * @param {object} playlistDetails - {name, songs, artworks}
 */
export function showSituationPlaylistDetail(playlistDetails) {
    state.currentlyViewedSongs = playlistDetails.songs;
    showView('playlist-detail-view', { type: 'situation', identifier: playlistDetails.name, data: playlistDetails });
}

export async function showPlaylist(playlistName) {
    const playlistDetails = await ipcRenderer.invoke('get-playlist-details', playlistName);
    state.currentlyViewedSongs = playlistDetails.songs;
    showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: playlistDetails });
}

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