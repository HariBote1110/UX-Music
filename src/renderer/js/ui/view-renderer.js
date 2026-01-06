// src/renderer/js/ui/view-renderer.js
import { state, elements } from '../state.js';
// ▼▼▼ 削除 (detail-renderer.js が担当) ▼▼▼
// import { showAlbum, showArtist } from '../navigation.js';
// import { playSong } from '../playback-manager.js';
// import { createAlbumGridItem } from './element-factory.js';
// import { createPlaylistArtwork } from './playlist-artwork.js';
// import { formatTime, resolveArtworkPath } from './utils.js';
// ▲▲▲ 削除 ▲▲▲
import { setVisualizerTarget, disconnectVisualizerObserver } from '../player.js';
import {
    createListHeader,
    setupSongListScroller,
    initListHeaderResizing
} from './list-renderer.js';
import {
    renderAlbumView,
    renderArtistView,
    renderSituationView,
    renderPlaylistView
} from './grid-renderer.js';
// ▼▼▼ 追加 ▼▼▼
import {
    renderAlbumDetailView as renderAlbumDetail,
    renderArtistDetailView as renderArtistDetail,
    renderPlaylistDetailView as renderPlaylistDetail
} from './detail-renderer.js';
// ▲▲▲ 追加 ▲▲▲
const { ipcRenderer } = require('electron'); // renderTrackView が使用

let trackViewScroller = null;
let detailViewScroller = null;
// const lastScrollPositions = {}; // detail-renderer.js に移動

/**
 * メインコンテンツをクリアし、スクローラーを破棄する
 */
export function clearMainContent() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
    if (detailViewScroller) {
        detailViewScroller.destroy();
        detailViewScroller = null;
    }
    disconnectVisualizerObserver();
    elements.mainContent.innerHTML = '';
    state.selectedSongIds.clear();
}

/**
 * トラックビューのスクローラー（もしあれば）を破棄する
 */
export function destroyTrackViewScroller() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
}

/**
 * 曲一覧（トラックビュー）を描画する
 */
export function renderTrackView() {
    clearMainContent();
    state.currentlyViewedSongs = state.library;
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.id = 'track-view';
    viewWrapper.innerHTML = `
        <h1>曲</h1>
        ${createListHeader()}
    `;
    const musicListContainer = document.createElement('div');
    musicListContainer.id = 'music-list';
    viewWrapper.appendChild(musicListContainer);
    elements.mainContent.appendChild(viewWrapper);

    if (state.library.length === 0) {
        musicListContainer.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }

    trackViewScroller = setupSongListScroller(musicListContainer, state.library, {
        contextView: 'library'
    });
    
    initListHeaderResizing(viewWrapper);
}

// ▼▼▼ 削除 (detail-renderer.js へ移動) ▼▼▼
// export function renderAlbumDetailView(album) { ... }
// export function renderArtistDetailView(artist) { ... }
// export function renderPlaylistDetailView(playlistDetails) { ... }
// ▲▲▲ 削除 ▲▲▲

// ▼▼▼ 追加 (detail-renderer.js へのラッパー関数) ▼▼▼
/**
 * アルバム詳細ビューを描画し、スクローラーを管理する
 * @param {object} album 
 */
export function renderAlbumDetailView(album) {
    detailViewScroller = renderAlbumDetail(album);
}

/**
 * アーティスト詳細ビューを描画し、スクローラーを管理する
 * @param {object} artist 
 */
export function renderArtistDetailView(artist) {
    detailViewScroller = renderArtistDetail(artist); // スクロラが無くても null が返る
}

/**
 * プレイリスト詳細ビューを描画し、スクローラーを管理する
 * @param {object} playlistDetails 
 */
export function renderPlaylistDetailView(playlistDetails) {
    detailViewScroller = renderPlaylistDetail(playlistDetails);
}
// ▲▲▲ 追加 ▲▲▲


// grid-renderer.js からインポートした関数を再エクスポート
export {
    renderAlbumView,
    renderArtistView,
    renderSituationView,
    renderPlaylistView
};